import XCTest
@testable import WCleanerCore

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [MonitorEvent] = []
    private var _snapshots = 0
    var events: [MonitorEvent] { lock.withLock { _events } }
    var snapshotCount: Int { lock.withLock { _snapshots } }
    func record(_ event: MonitorEvent) { lock.withLock { _events.append(event) } }
    func recordSnapshot() { lock.withLock { _snapshots += 1 } }
}

/// End-to-end scans against a disposable repository and a mocked GitHub API. No network access.
final class MonitorEngineTests: XCTestCase {
    private let alice = AccountID(host: "github.com", userID: 1)
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")
    /// Before the fixture pull request's merge time (2026-05-01).
    private let enrolledAt = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!

    private var fixture: TemporaryGitRepository!
    private var worktree: String!
    private var head: String!
    private var transport: MockHTTPTransport!
    private var registry: RepositoryRegistry!
    private var accounts: GitHubAccountStore!
    private var tracking: WorktreeTrackingStore!
    private var history: CleanupHistoryStore!
    private var events: EventRecorder!
    private var live: LiveSettingsBox!

    override func setUp() async throws {
        fixture = try TemporaryGitRepository()
        try fixture.git(["remote", "add", "origin", "https://github.com/octo/repo.git"])
        worktree = try fixture.addWorktree("wt-feature", branch: "feature")
        try fixture.write("feature.txt", "work\n", in: worktree)
        try fixture.git(["add", "feature.txt"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Feature"], in: worktree)
        head = try fixture.head(of: worktree)

        let data = AppDataDirectory(url: URL(fileURLWithPath: fixture.root + "/appdata"))
        transport = MockHTTPTransport()
        registry = RepositoryRegistry(store: JSONFileStore(directory: data, fileName: "repositories.json"), git: TemporaryGitRepository.client)
        accounts = GitHubAccountStore(store: JSONFileStore(directory: data, fileName: "accounts.json"))
        tracking = WorktreeTrackingStore(directory: data)
        history = CleanupHistoryStore(directory: data)
        events = EventRecorder()
        live = LiveSettingsBox(AppSettings())
        try await accounts.upsert(GitHubAccount(id: alice, login: "alice"))
        transport.json(path: "/repos/octo/repo", token: "token-alice", GitHubFixtures.repository(id: 10, owner: "octo", name: "repo"))
    }

    override func tearDown() {
        fixture?.cleanup()
    }

    private func servePullRequest(merged: Bool = true, state: String = "closed", sha: String? = nil) {
        let body = GitHubFixtures.pullRequest(
            number: 5,
            state: state,
            mergedAt: merged ? "2026-05-01T10:00:00Z" : nil,
            headSHA: sha ?? head,
            headRef: "feature",
            headRepo: (10, "octo/repo"),
            baseRepo: (10, "octo/repo")
        )
        transport.on({ request in
            request.url?.path == "/repos/octo/repo/pulls"
                && (request.url?.query?.removingPercentEncoding?.contains("head=octo:feature") ?? false)
        }) { _ in (200, [:], Data("[\(body)]".utf8)) }
        transport.json(path: "/repos/octo/repo/pulls/5", body)
    }

    private func makeEngine(withExecutor: Bool = true, addedAt: Date? = nil) async throws -> (MonitorEngine, RegisteredRepository) {
        let repository = try await registry.add(path: fixture.repositoryPath, now: addedAt ?? enrolledAt)
        let git = TemporaryGitRepository.client
        let api = GitHubAPIClient(transport: transport, configuration: configuration)
        let tokens = FakeTokens([alice: "token-alice"])
        let resolver = RepositoryAccountResolver(
            configuration: configuration,
            api: api,
            tokens: tokens,
            accounts: accounts,
            mappings: RepositoryAccountMappingStore(store: JSONFileStore(directory: AppDataDirectory(url: URL(fileURLWithPath: fixture.root + "/appdata")), fileName: "mappings.json")),
            aliasResolver: StaticAliasResolver(aliases: [:])
        )
        let matcher = PullRequestMatcher(api: api, tokens: tokens)
        let live = self.live!
        let executor = CleanupExecutor(
            git: git,
            evidence: LiveCleanupEvidence(git: git, resolver: resolver, matcher: matcher, accounts: accounts),
            tracking: tracking,
            history: history,
            registry: registry,
            policy: DeletionPolicy(allowsRealRemoval: true),
            settings: { live.read() }
        )
        let engine = MonitorEngine(
            registry: registry,
            git: git,
            resolver: resolver,
            matcher: matcher,
            api: api,
            accounts: accounts,
            tracking: tracking,
            diskUsage: DiskUsageService(),
            history: history,
            executor: withExecutor ? executor : nil,
            liveSettings: { live.read() }
        )
        let events = self.events!
        await engine.setEventObserver { events.record($0) }
        await engine.setSnapshotObserver { _ in events.recordSnapshot() }
        return (engine, repository)
    }

    private func settings(consent: Bool, auto: Bool = false) -> AppSettings {
        var settings = AppSettings()
        settings.cleanupConsentAt = consent ? enrolledAt : nil
        settings.autoCleanupEnabled = auto && consent
        settings.cleanupDelay = .none
        return settings
    }

    /// Scans with `settings`, which are also what the engine and the executor read live.
    @discardableResult
    private func scan(_ engine: MonitorEngine, _ trigger: ScanTrigger, _ settings: AppSettings) async -> ScanOutcome {
        live.value = settings
        return await engine.scan(trigger: trigger, settings: settings)
    }

    private func linked(_ engine: MonitorEngine) async -> [WorktreeSnapshot] {
        await engine.currentSnapshot().allLinkedWorktrees
    }

    // MARK: Dry run

    func testDryRunScanProducesDecisionsWithoutRemovingAnything() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine()
        let outcome = await scan(engine, .manual, settings(consent: false))
        XCTAssertEqual(outcome, .success)

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.repositories.count, 1)
        XCTAssertEqual(snapshot.repositories.first?.accountResolution, .assigned(alice, automatic: true))
        XCTAssertEqual(snapshot.repositories.first?.accountLogin, "alice")
        let worktrees = snapshot.allLinkedWorktrees
        XCTAssertEqual(worktrees.map(\.path), [worktree])
        XCTAssertEqual(worktrees.first?.decision.verdict, .eligible)
        XCTAssertEqual(worktrees.first?.decision.automaticCleanupAllowed, false)
        XCTAssertTrue(worktrees.first?.decision.reasons.contains(.cleanupConsentMissing) ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
        XCTAssertEqual(snapshot.repositories.first?.worktrees.first?.isPrimary, true)
        XCTAssertEqual(snapshot.repositories.first?.worktrees.first?.decision.verdict, .blocked)
        XCTAssertGreaterThan(events.snapshotCount, 1)
    }

    func testOpenPullRequestIsBlocked() async throws {
        servePullRequest(merged: false, state: "open")
        let (engine, _) = try await makeEngine()
        await scan(engine, .manual, settings(consent: true, auto: true))
        let decision = await linked(engine).first?.decision
        XCTAssertEqual(decision?.verdict, .blocked)
        XCTAssertTrue(decision?.reasons.contains(.pullRequestOpen(5)) ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
    }

    func testGitHubOutageIsANetworkFailureAndBlocksCleanup() async throws {
        transport.on({ _ in true }) { _ in (502, [:], Data()) }
        let (engine, _) = try await makeEngine()
        let outcome = await scan(engine, .scheduled, settings(consent: true, auto: true))
        XCTAssertEqual(outcome, .networkFailure)
        let decision = await linked(engine).first?.decision
        XCTAssertEqual(decision?.verdict, .blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        let error = await engine.currentSnapshot().lastScanError
        XCTAssertNotNil(error)
    }

    func testRateLimitIsReported() async throws {
        let reset = Date().addingTimeInterval(900)
        transport.on(path: "/repos/octo/repo/pulls") { _ in
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))], Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        }
        let (engine, _) = try await makeEngine()
        let outcome = await scan(engine, .scheduled, settings(consent: true, auto: true))
        guard case .rateLimited(let until) = outcome else { return XCTFail("Got \(outcome)") }
        XCTAssertEqual(until?.timeIntervalSince1970 ?? 0, Double(Int(reset.timeIntervalSince1970)), accuracy: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
    }

    // MARK: Automatic cleanup

    func testAutomaticCleanupRemovesEligibleWorktreeAfterFreshVerification() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine()
        await scan(engine, .scheduled, settings(consent: true, auto: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        let remaining = await linked(engine)
        XCTAssertTrue(remaining.isEmpty)
        guard case .cleanupCompleted(let outcome)? = events.events.first(where: { if case .cleanupCompleted = $0 { return true }; return false }) else {
            return XCTFail("No cleanup event: \(events.events)")
        }
        XCTAssertTrue(outcome.didRemove)
        XCTAssertEqual(outcome.entry.mode, .automatic)
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/repos/octo/repo/pulls/5" }, "Fresh PR evidence must be fetched before removal")
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/heads/feature"]), head)
    }

    func testDirtyWorktreeIsNeverHandedToTheExecutor() async throws {
        servePullRequest()
        try fixture.write("scratch.txt", "keep\n", in: worktree)
        let (engine, _) = try await makeEngine()
        await scan(engine, .scheduled, settings(consent: true, auto: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/scratch.txt"))
        XCTAssertFalse(events.events.contains { if case .cleanupCompleted = $0 { return true }; return false })
    }

    func testWithoutExecutorNothingIsRemoved() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine(withExecutor: false)
        await scan(engine, .scheduled, settings(consent: true, auto: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
    }

    // MARK: Review and manual actions

    func testMergedBeforeEnrollmentNeedsReviewUntilApproved() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine(addedAt: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!)
        var current = settings(consent: true, auto: true)
        current.cleanupConsentAt = repository.addedAt

        await scan(engine, .scheduled, current)
        let beforeReview = await linked(engine).first?.decision.verdict
        XCTAssertEqual(beforeReview, .needsReview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "Pre-enrollment merges are never cleaned automatically")
        XCTAssertEqual(events.events.filter { if case .reviewRequired = $0 { return true }; return false }.count, 1)

        await scan(engine, .scheduled, current)
        XCTAssertEqual(events.events.filter { if case .reviewRequired = $0 { return true }; return false }.count, 1, "Reported once")

        var manualOnly = current
        manualOnly.autoCleanupEnabled = false
        try await engine.approveReview(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: 5, expectedHead: head, settings: manualOnly)
        let afterReview = await linked(engine).first?.decision.verdict
        XCTAssertEqual(afterReview, .eligible)
        let reviewed = await history.entries().first
        XCTAssertEqual(reviewed?.result, .reviewed)
        XCTAssertEqual(reviewed?.pullRequestNumber, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
    }

    func testApproveRejectsWorktreesThatAreNotAwaitingReview() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine()
        await scan(engine, .manual, settings(consent: true))
        do {
            try await engine.approveReview(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: 5, expectedHead: head, settings: settings(consent: true))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? MonitorActionError, .notAwaitingReview)
        }
    }

    func testManualRemovalOfEligibleWorktree() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine()
        let manual = settings(consent: true)
        await scan(engine, .manual, manual)
        let outcome = try await engine.removeWorktree(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: 5, expectedHead: head, settings: manual)
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
        XCTAssertEqual(outcome.entry.mode, .manual)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        let remaining = await linked(engine)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testManualRemovalOfBlockedWorktreeIsRejected() async throws {
        servePullRequest()
        try fixture.write("feature.txt", "edited\n", in: worktree)
        let (engine, repository) = try await makeEngine()
        let manual = settings(consent: true)
        await scan(engine, .manual, manual)
        do {
            _ = try await engine.removeWorktree(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: 5, expectedHead: head, settings: manual)
            XCTFail("Expected an error")
        } catch let error as MonitorActionError {
            guard case .notSafeToRemove(let reasons) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(reasons.contains(.unstagedChanges(1)))
        }
        XCTAssertEqual(try String(contentsOfFile: worktree + "/feature.txt", encoding: .utf8), "edited\n")
    }

    /// A dialog shows one pull request and commit; if either changed by the time the user confirms, nothing happens.
    func testStaleDialogApprovalIsRejected() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine(addedAt: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!)
        var current = settings(consent: true)
        current.cleanupConsentAt = repository.addedAt
        await scan(engine, .manual, current)
        let verdict = await linked(engine).first?.decision.verdict
        XCTAssertEqual(verdict, .needsReview)

        for (number, sha) in [(6, head!), (5, EligibilityFixture.otherHead)] {
            do {
                try await engine.approveReview(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: number, expectedHead: sha, settings: current)
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? MonitorActionError, .stateChanged)
            }
        }
        let approval = await tracking.tracking(for: WorktreeKey(repositoryID: repository.id, path: worktree))?.reviewApproval
        XCTAssertNil(approval)
    }

    func testStaleDialogRemovalIsRejected() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine()
        let manual = settings(consent: true)
        await scan(engine, .manual, manual)
        for (number, sha) in [(6, head!), (5, EligibilityFixture.otherHead)] {
            do {
                _ = try await engine.removeWorktree(repositoryID: repository.id, worktreePath: worktree, expectedPullRequest: number, expectedHead: sha, settings: manual)
                XCTFail("Expected an error")
            } catch {
                XCTAssertEqual(error as? MonitorActionError, .stateChanged)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
    }

    func testPauseDuringScanStopsTheAutomaticBatch() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine()
        let automatic = settings(consent: true, auto: true)
        live.value = automatic
        live.setOnRead { _, settings in settings.autoCleanupPaused = true }
        await engine.scan(trigger: .scheduled, settings: automatic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
        XCTAssertFalse(events.events.contains { if case .cleanupCompleted = $0 { return true }; return false }, "The executor is not even asked")
    }

    /// The dry run shows the same deep checks the executor runs, so it never promises a removal that would be refused.
    func testDryRunIncludesDeepChecksForRemovableWorktrees() async throws {
        servePullRequest()
        try fixture.git(["update-index", "--skip-worktree", "feature.txt"], in: worktree)
        try fixture.write("feature.txt", "local only\n", in: worktree)
        let (engine, _) = try await makeEngine(withExecutor: false)
        await scan(engine, .manual, settings(consent: true))
        let decision = await linked(engine).first?.decision
        XCTAssertEqual(decision?.verdict, .blocked)
        XCTAssertTrue(decision?.reasons.contains(.hiddenIndexEntries(1)) ?? false, "\(String(describing: decision?.reasons))")
    }

    func testCleanupDelayStartsOnlyOnceTheWorktreeIsOtherwiseEligible() async throws {
        servePullRequest()
        try fixture.write("scratch.txt", "keep\n", in: worktree)
        let (engine, repository) = try await makeEngine(withExecutor: false)
        var delayed = settings(consent: true, auto: true)
        delayed.cleanupDelay = .oneHour
        let key = WorktreeKey(repositoryID: repository.id, path: worktree)

        await scan(engine, .manual, delayed)
        let whileBlocked = await tracking.tracking(for: key)?.mergeConfirmedAt
        XCTAssertNil(whileBlocked, "A blocked worktree does not start the delay")

        try FileManager.default.removeItem(atPath: worktree + "/scratch.txt")
        let cleanedAt = Date()
        await scan(engine, .manual, delayed)
        let confirmedAt = await tracking.tracking(for: key)?.mergeConfirmedAt
        XCTAssertNotNil(confirmedAt)
        XCTAssertGreaterThanOrEqual(confirmedAt ?? .distantPast, cleanedAt.addingTimeInterval(-1))
        guard case .waiting = await linked(engine).first?.decision.verdict else {
            return XCTFail("Expected the delay to run from now")
        }
    }

    /// Withdrawing consent moves the review cutoff back to enrollment, so a worktree that needed review can
    /// become removable without a scan. It must get the deep checks before the menu calls it safe.
    func testSettingsChangeRunsDeepChecksBeforeShowingAWorktreeAsSafe() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine(withExecutor: false)
        var consentAfterMerge = settings(consent: true)
        consentAfterMerge.cleanupConsentAt = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
        await scan(engine, .manual, consentAfterMerge)
        let beforeChange = await linked(engine).first?.decision.verdict
        XCTAssertEqual(beforeChange, .needsReview)

        try fixture.git(["update-index", "--skip-worktree", "feature.txt"], in: worktree)
        try fixture.write("feature.txt", "local only\n", in: worktree)
        let requestCount = transport.requests.count
        await engine.settingsChanged(settings(consent: false))

        let decision = await linked(engine).first?.decision
        XCTAssertEqual(decision?.verdict, .blocked)
        XCTAssertTrue(decision?.reasons.contains(.hiddenIndexEntries(1)) ?? false, "\(String(describing: decision?.reasons))")
        XCTAssertEqual(transport.requests.count, requestCount, "No network")
    }

    func testSettingsChangeReevaluatesWithoutNetwork() async throws {
        servePullRequest()
        let (engine, _) = try await makeEngine(withExecutor: false)
        await scan(engine, .manual, settings(consent: false))
        let requestCount = transport.requests.count
        let before = await linked(engine).first?.decision
        XCTAssertTrue(before?.reasons.contains(.cleanupConsentMissing) ?? false)

        await engine.settingsChanged(settings(consent: true))
        let decision = await linked(engine).first?.decision
        XCTAssertTrue(decision?.reasons.contains(.automaticCleanupOff) ?? false)
        XCTAssertEqual(transport.requests.count, requestCount)
    }

    func testRemovingARepositoryClearsItsState() async throws {
        servePullRequest()
        let (engine, repository) = try await makeEngine(withExecutor: false)
        await scan(engine, .manual, settings(consent: false))
        try await registry.remove(id: repository.id)
        await engine.repositoryRemoved(repository.id)
        let snapshot = await engine.currentSnapshot()
        XCTAssertTrue(snapshot.repositories.isEmpty)
        let stored = await tracking.tracking(for: WorktreeKey(repositoryID: repository.id, path: worktree))
        XCTAssertNil(stored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree), "Removing a repository from WCleaner never touches its files")
    }
}
