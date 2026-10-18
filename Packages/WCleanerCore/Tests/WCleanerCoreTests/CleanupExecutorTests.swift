import XCTest
@testable import WCleanerCore

/// Configurable stand-in for the live GitHub checks. Can hold the first call open to test serialization.
final class FakeCleanupEvidence: CleanupEvidenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _resolution: RepositoryResolution
    private var _evidence: Result<PullRequestEvidence, GitHubAPIError>
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false
    private var _entered = 0

    init(resolution: RepositoryResolution, evidence: Result<PullRequestEvidence, GitHubAPIError>) {
        _resolution = resolution
        _evidence = evidence
    }

    var entered: Int { lock.withLock { _entered } }

    func set(evidence: Result<PullRequestEvidence, GitHubAPIError>) { lock.withLock { _evidence = evidence } }
    func set(resolution: RepositoryResolution) { lock.withLock { _resolution = resolution } }
    func holdNextCall() { lock.withLock { holdNext = true } }
    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    func freshResolution(for repository: RegisteredRepository) async -> RepositoryResolution {
        let hold = lock.withLock { () -> Bool in
            _entered += 1
            defer { holdNext = false }
            return holdNext
        }
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { gate = continuation }
            }
        }
        return lock.withLock { _resolution }
    }

    func freshPullRequest(number: Int, base: ResolvedGitHubRepository, account: AccountID, expectedHeadRepositoryFullName: String?) async throws -> PullRequestEvidence {
        try lock.withLock { try _evidence.get() }
    }

    func accountLogin(_ id: AccountID) async -> String? { "alice" }
}

/// The settings as the executor reads them at each check. `onRead` runs on every read (numbered from 1)
/// so a test can change the settings, or the worktree, between two of the executor's checks.
final class LiveSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: AppSettings
    private var reads = 0
    private var onRead: (@Sendable (Int, inout AppSettings) -> Void)?

    init(_ value: AppSettings) { _value = value }

    var value: AppSettings {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Installs `hook` and restarts the read count.
    func setOnRead(_ hook: @escaping @Sendable (Int, inout AppSettings) -> Void) {
        lock.withLock {
            onRead = hook
            reads = 0
        }
    }

    func read() -> AppSettings {
        lock.withLock {
            reads += 1
            onRead?(reads, &_value)
            return _value
        }
    }
}

/// Destructive tests: they only ever run against freshly generated repositories in the temporary
/// directory, which are deleted afterwards. Nothing here touches a real repository.
final class CleanupExecutorTests: XCTestCase {
    private let account = AccountID(host: "github.com", userID: 42)
    private let github = ResolvedGitHubRepository(id: 1001, owner: "octo", name: "repo", htmlURL: "https://github.com/octo/repo")
    private let enrolledAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { enrolledAt.addingTimeInterval(86_400) }

    private var fixture: TemporaryGitRepository!
    private var worktree: String!
    private var head: String!
    private var repository: RegisteredRepository!
    private var evidence: FakeCleanupEvidence!
    private var history: CleanupHistoryStore!
    private var tracking: WorktreeTrackingStore!
    private var registry: RepositoryRegistry!
    private var live: LiveSettingsBox!

    override func setUp() async throws {
        fixture = try TemporaryGitRepository()
        worktree = try fixture.addWorktree("wt-feature", branch: "feature")
        try fixture.write("feature.txt", "work\n", in: worktree)
        try fixture.git(["add", "feature.txt"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Feature"], in: worktree)
        head = try fixture.head(of: worktree)
        let data = AppDataDirectory(url: URL(fileURLWithPath: fixture.root + "/appdata"))
        registry = RepositoryRegistry(store: JSONFileStore(directory: data, fileName: "repositories.json"), git: TemporaryGitRepository.client)
        repository = try await registry.add(path: fixture.repositoryPath, now: enrolledAt)
        evidence = FakeCleanupEvidence(
            resolution: RepositoryResolution(resolution: .assigned(account, automatic: true), githubRepository: github, remotes: [], githubRemotes: [:]),
            evidence: .success(pullRequest())
        )
        history = CleanupHistoryStore(directory: data)
        tracking = WorktreeTrackingStore(directory: data)
        live = LiveSettingsBox(settings())
    }

    override func tearDown() {
        fixture?.cleanup()
    }

    private func pullRequest(state: PullRequestState = .merged, head: String? = nil, mergedAt: Date? = nil) -> PullRequestEvidence {
        PullRequestEvidence(
            number: 12,
            title: "Feature",
            url: "https://github.com/octo/repo/pull/12",
            state: state,
            mergedAt: state == .merged ? (mergedAt ?? enrolledAt.addingTimeInterval(3600)) : nil,
            headSHA: head ?? self.head,
            headRef: "feature",
            headRepositoryID: 1001,
            headRepositoryFullName: "octo/repo",
            baseRepositoryID: 1001,
            baseRef: "main",
            accountID: account,
            fetchedAt: now,
            headRepositoryVerified: true
        )
    }

    private func settings(consent: Bool = true, auto: Bool = true, paused: Bool = false, delay: CleanupDelay = .none) -> AppSettings {
        var settings = AppSettings()
        settings.cleanupConsentAt = consent ? enrolledAt : nil
        settings.autoCleanupEnabled = auto && consent
        settings.autoCleanupPaused = paused
        settings.cleanupDelay = delay
        return settings
    }

    private func makeExecutor(
        git: GitClient = TemporaryGitRepository.client,
        allowRemoval: Bool = true,
        settings: (@Sendable () async -> AppSettings)? = nil
    ) -> CleanupExecutor {
        let now = self.now
        let live = self.live!
        return CleanupExecutor(
            git: git,
            evidence: evidence,
            tracking: tracking,
            history: history,
            registry: registry,
            policy: DeletionPolicy(allowsRealRemoval: allowRemoval),
            settings: settings ?? { live.read() },
            now: { now }
        )
    }

    private func request(
        path: String? = nil,
        expectedHead: String? = nil,
        mode: CleanupMode = .manual
    ) -> CleanupRequest {
        CleanupRequest(
            repository: repository,
            worktreePath: path ?? worktree,
            expectedHead: expectedHead ?? head,
            expectedPullRequest: mode == .manualUnmerged ? nil : 12,
            expectedHeadRepositoryFullName: "octo/repo",
            githubRepositoryFullName: "octo/repo",
            mode: mode,
            estimatedSizeBytes: 4096
        )
    }

    private func assertRefused(
        _ outcome: CleanupOutcome,
        _ matches: (EligibilityReason) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .refused(let entry, let reasons) = outcome else {
            return XCTFail("Expected refusal, got \(outcome)", file: file, line: line)
        }
        XCTAssertTrue(reasons.contains(where: matches), "Unexpected reasons: \(reasons)", file: file, line: line)
        XCTAssertEqual(entry.result, .refused, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"), "Worktree contents must remain", file: file, line: line)
    }

    private func listedPaths() throws -> [String] {
        try fixture.git(["worktree", "list", "--porcelain"])
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    // MARK: Success

    func testCleanMergedWorktreeIsRemovedWithGitAndBranchIsKept() async throws {
        let outcome = await makeExecutor().execute(request())
        guard case .removed(let entry) = outcome else { return XCTFail("Expected removal, got \(outcome)") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(try listedPaths().contains(worktree))
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/heads/feature"]), head, "The branch is never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repositoryPath + "/README.md"), "The primary worktree is untouched")

        XCTAssertEqual(entry.result, .removed)
        XCTAssertEqual(entry.pullRequestNumber, 12)
        XCTAssertEqual(entry.accountLogin, "alice")
        XCTAssertEqual(entry.githubRepository, "octo/repo")
        XCTAssertFalse(entry.rationale.isEmpty)
        let logged = await history.entries()
        XCTAssertEqual(logged.first?.result, .removed)
    }

    func testAutomaticModeRemovesWhenEveryPolicyAllowsIt() async {
        let outcome = await makeExecutor().execute(request(mode: .automatic))
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
    }

    // MARK: Local content blocks removal

    func testUnstagedChangeBlocksRemoval() async throws {
        try fixture.write("feature.txt", "changed\n", in: worktree)
        assertRefused(await makeExecutor().execute(request())) { if case .unstagedChanges = $0 { return true }; return false }
    }

    func testStagedChangeBlocksRemoval() async throws {
        try fixture.write("staged.txt", "new\n", in: worktree)
        try fixture.git(["add", "staged.txt"], in: worktree)
        assertRefused(await makeExecutor().execute(request())) { if case .stagedChanges = $0 { return true }; return false }
    }

    func testUntrackedFileBlocksRemoval() async throws {
        try fixture.write("notes.txt", "keep me\n", in: worktree)
        assertRefused(await makeExecutor().execute(request())) { if case .untrackedFiles = $0 { return true }; return false }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes.txt"))
    }

    func testIgnoredFileBlocksRemoval() async throws {
        try fixture.write(".gitignore", "build/\n.env\n", in: worktree)
        try fixture.git(["add", ".gitignore"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Ignore"], in: worktree)
        head = try fixture.head(of: worktree)
        evidence.set(evidence: .success(pullRequest()))
        try fixture.write(".env", "SECRET=1\n", in: worktree)

        assertRefused(await makeExecutor().execute(request())) { if case .ignoredFiles = $0 { return true }; return false }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/.env"))
    }

    /// Git's status hides changes to skip-worktree and assume-unchanged files; removal would lose them.
    func testSkipWorktreeEntryBlocksRemoval() async throws {
        try fixture.git(["update-index", "--skip-worktree", "feature.txt"], in: worktree)
        try fixture.write("feature.txt", "local only\n", in: worktree)
        XCTAssertEqual(try fixture.git(["status", "--porcelain", "--ignored"], in: worktree), "", "Precondition: status looks clean")

        assertRefused(await makeExecutor().execute(request())) { $0 == .hiddenIndexEntries(1) }
        XCTAssertEqual(try String(contentsOfFile: worktree + "/feature.txt", encoding: .utf8), "local only\n")
    }

    func testAssumeUnchangedEntryBlocksRemoval() async throws {
        try fixture.git(["update-index", "--assume-unchanged", "feature.txt"], in: worktree)
        try fixture.write("feature.txt", "local only\n", in: worktree)
        XCTAssertEqual(try fixture.git(["status", "--porcelain", "--ignored"], in: worktree), "", "Precondition: status looks clean")

        assertRefused(await makeExecutor().execute(request())) { $0 == .hiddenIndexEntries(1) }
        XCTAssertEqual(try String(contentsOfFile: worktree + "/feature.txt", encoding: .utf8), "local only\n")
    }

    /// Refs under refs/worktree, refs/bisect and refs/rewritten belong to one worktree and go away with it.
    func testPerWorktreeRefBlocksRemoval() async throws {
        try fixture.git(["update-ref", "refs/worktree/keep", head], in: worktree)
        assertRefused(await makeExecutor().execute(request())) { $0 == .perWorktreeRefs(["refs/worktree/keep"]) }
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/worktree/keep"], in: worktree), head)
    }

    func testIgnoredFileCreatedJustBeforeRemovalBlocksIt() async throws {
        try fixture.write(".gitignore", ".env\n", in: worktree)
        try fixture.git(["add", ".gitignore"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Ignore"], in: worktree)
        head = try fixture.head(of: worktree)
        evidence.set(evidence: .success(pullRequest()))
        // The third settings read happens after the deep inspection, right before the final status check.
        let envFile = worktree + "/.env"
        live.setOnRead { read, _ in
            if read == 3 { try? "SECRET=1\n".write(toFile: envFile, atomically: true, encoding: .utf8) }
        }

        assertRefused(await makeExecutor().execute(request())) { $0 == .expectationChanged("The worktree changed during verification.") }
        XCTAssertEqual(try String(contentsOfFile: envFile, encoding: .utf8), "SECRET=1\n")
    }

    /// Git skips folders named .git in status (even with --ignored), and `git worktree remove` deletes them.
    func testNestedGitFolderBlocksRemoval() async throws {
        try FileManager.default.createDirectory(atPath: worktree + "/docs/.GIT", withIntermediateDirectories: true)
        try "keep\n".write(toFile: worktree + "/docs/.GIT/notes.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.git(["status", "--porcelain", "--ignored"], in: worktree), "", "Precondition: Git does not see it")

        assertRefused(await makeExecutor().execute(request())) { $0 == .nestedGitEntries(["docs/.GIT"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/docs/.GIT/notes.txt"))
    }

    /// The last check before removal repeats every local check, not only status and HEAD.
    func testNestedGitFolderCreatedJustBeforeRemovalBlocksIt() async throws {
        let notes = worktree + "/docs/.git/notes.txt"
        let folder = worktree + "/docs/.git"
        live.setOnRead { read, _ in
            if read == 3 {
                try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try? "keep\n".write(toFile: notes, atomically: true, encoding: .utf8)
            }
        }
        assertRefused(await makeExecutor().execute(request())) { $0 == .nestedGitEntries(["docs/.git"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes))
    }

    /// Commits a submodule entry (`.gitmodules` and a gitlink at `lib`) without cloning anything, and leaves
    /// `lib` as the empty folder Git creates for a submodule that was never initialized.
    private func addSubmoduleThatIsNotCheckedOut() throws {
        try fixture.write(".gitmodules", "[submodule \"lib\"]\n\tpath = lib\n\turl = https://example.invalid/lib.git\n", in: worktree)
        try fixture.git(["add", ".gitmodules"], in: worktree)
        try fixture.git(["update-index", "--add", "--cacheinfo", "160000,\(head!),lib"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Submodule"], in: worktree)
        try FileManager.default.createDirectory(atPath: worktree + "/lib", withIntermediateDirectories: false)
        head = try fixture.head(of: worktree)
        evidence.set(evidence: .success(pullRequest()))
        XCTAssertEqual(try fixture.git(["status", "--porcelain", "--ignored"], in: worktree), "", "Precondition: clean")
    }

    func testSubmoduleThatWasNeverCheckedOutDoesNotBlockRemoval() async throws {
        try addSubmoduleThatIsNotCheckedOut()
        let outcome = await makeExecutor().execute(request())
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/heads/feature"]), head, "The branch is never deleted")
    }

    /// Git's status does not look inside a submodule folder without a repository; its files would be lost.
    func testFilesInsideASubmoduleFolderBlockRemoval() async throws {
        try addSubmoduleThatIsNotCheckedOut()
        try fixture.write("lib/notes.txt", "keep\n", in: worktree)
        XCTAssertEqual(try fixture.git(["status", "--porcelain", "--ignored"], in: worktree), "", "Precondition: Git does not see it")

        assertRefused(await makeExecutor().execute(request())) { $0 == .checkedOutSubmodules(["lib"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/lib/notes.txt"))
    }

    func testSymbolicLinkAtASubmodulePathBlocksRemoval() async throws {
        try addSubmoduleThatIsNotCheckedOut()
        try FileManager.default.removeItem(atPath: worktree + "/lib")
        try FileManager.default.createSymbolicLink(atPath: worktree + "/lib", withDestinationPath: fixture.repositoryPath)
        assertRefused(await makeExecutor().execute(request())) { $0 == .checkedOutSubmodules(["lib"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repositoryPath + "/README.md"))
    }

    func testSubmoduleRepositoriesInTheWorktreeGitFolderBlockRemoval() async throws {
        try addSubmoduleThatIsNotCheckedOut()
        let gitDirectory = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: worktree)
        try FileManager.default.createDirectory(atPath: gitDirectory + "/modules/lib", withIntermediateDirectories: true)
        assertRefused(await makeExecutor().execute(request())) { $0 == .submodules }
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDirectory + "/modules/lib"))
    }

    // MARK: Removal without a merged pull request

    func testCleanWorktreeWithAnOpenPullRequestIsRemovedOnRequestAndBranchIsKept() async throws {
        evidence.set(evidence: .success(pullRequest(state: .open)))
        let outcome = await makeExecutor().execute(request(mode: .manualUnmerged))
        guard case .removed(let entry) = outcome else { return XCTFail("Expected removal, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertFalse(try listedPaths().contains(worktree))
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/heads/feature"]), head, "The branch and its commits are kept")
        XCTAssertEqual(entry.mode, .manualUnmerged)
        XCTAssertNil(entry.pullRequestNumber)
        XCTAssertTrue(entry.rationale.contains { $0.contains("without a merged pull request") })
        XCTAssertEqual(evidence.entered, 0, "No GitHub evidence is needed")
    }

    func testRemovalWithoutAMergedPullRequestNeedsNoAccountOrPullRequest() async throws {
        evidence.set(resolution: RepositoryResolution(resolution: .needsAccount, githubRepository: nil, remotes: [], githubRemotes: [:]))
        evidence.set(evidence: .failure(.notFound))
        let outcome = await makeExecutor().execute(request(mode: .manualUnmerged))
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
    }

    func testRemovalWithoutAMergedPullRequestStillNeedsConsent() async throws {
        live.value = settings(consent: false)
        assertRefused(await makeExecutor().execute(request(mode: .manualUnmerged))) { $0 == .cleanupConsentMissing }
    }

    func testRemovalWithoutAMergedPullRequestKeepsEveryLocalCheck() async throws {
        try fixture.write("notes.txt", "keep me\n", in: worktree)
        assertRefused(await makeExecutor().execute(request(mode: .manualUnmerged))) { $0 == .untrackedFiles(1) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes.txt"))

        try FileManager.default.removeItem(atPath: worktree + "/notes.txt")
        try fixture.write("feature.txt", "changed\n", in: worktree)
        assertRefused(await makeExecutor().execute(request(mode: .manualUnmerged))) { if case .unstagedChanges = $0 { true } else { false } }

        try fixture.git(["checkout", "--", "feature.txt"], in: worktree)
        try fixture.git(["update-ref", "refs/worktree/keep", head], in: worktree)
        assertRefused(await makeExecutor().execute(request(mode: .manualUnmerged))) { $0 == .perWorktreeRefs(["refs/worktree/keep"]) }
    }

    func testRemovalWithoutAMergedPullRequestNeverRemovesThePrimaryWorktree() async throws {
        let primaryHead = try fixture.head()
        let outcome = await makeExecutor().execute(request(path: fixture.repositoryPath, expectedHead: primaryHead, mode: .manualUnmerged))
        guard case .refused(_, let reasons) = outcome else { return XCTFail("Expected refusal, got \(outcome)") }
        XCTAssertTrue(reasons.contains(.primaryWorktree), "\(reasons)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repositoryPath + "/README.md"))
    }

    func testRemovalWithoutAMergedPullRequestStopsWhenAFileAppearsJustBefore() async throws {
        let notes = worktree + "/notes.txt"
        live.setOnRead { read, _ in
            // The third read is the last settings check, right before the final inspection.
            if read == 3 { try? "keep\n".write(toFile: notes, atomically: true, encoding: .utf8) }
        }
        assertRefused(await makeExecutor().execute(request(mode: .manualUnmerged))) { $0 == .expectationChanged("The worktree changed during verification.") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes))
    }

    func testMergedModesRequireAPullRequestNumber() async throws {
        var withoutNumber = request()
        withoutNumber.expectedPullRequest = nil
        assertRefused(await makeExecutor().execute(withoutNumber)) { if case .expectationChanged = $0 { true } else { false } }
    }

    // MARK: Saving changes in a stash, then removing

    private func stashList() throws -> String {
        try fixture.git(["stash", "list", "--format=%H %s"])
    }

    private func makeChanges() throws {
        try fixture.write("feature.txt", "changed\n", in: worktree)
        try fixture.write("staged.txt", "staged\n", in: worktree)
        try fixture.git(["add", "staged.txt"], in: worktree)
        try fixture.write("notes/todo.txt", "untracked\n", in: worktree)
    }

    func testChangesAreSavedInAStashAndThenTheWorktreeIsRemoved() async throws {
        try makeChanges()
        let outcome = await makeExecutor().execute(request(mode: .manualStashed))
        guard case .removed(let entry) = outcome else { return XCTFail("Expected removal, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertEqual(try fixture.git(["rev-parse", "--verify", "refs/heads/feature"]), head, "The branch is kept")

        let stash = try XCTUnwrap(entry.stashCommit)
        let list = try stashList()
        XCTAssertTrue(list.contains("\(stash) On feature: WCleaner "), list)
        XCTAssertEqual(try fixture.git(["rev-parse", "\(stash)^1"]), head, "Made on the worktree's HEAD")
        XCTAssertEqual(try fixture.git(["show", "\(stash):feature.txt"]), "changed", "Unstaged change saved")
        XCTAssertEqual(try fixture.git(["show", "\(stash)^2:staged.txt"]), "staged", "Staged file saved")
        XCTAssertEqual(try fixture.git(["show", "\(stash)^3:notes/todo.txt"]), "untracked", "Untracked file saved")
        XCTAssertEqual(entry.mode, .manualStashed)
        XCTAssertTrue(entry.rationale.contains { $0.contains("git stash apply \(stash)") }, "\(entry.rationale)")
    }

    func testNothingIsStashedWhenAnotherLocalCheckFails() async throws {
        try fixture.write(".gitignore", ".env\n", in: worktree)
        try fixture.git(["add", ".gitignore"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Ignore"], in: worktree)
        head = try fixture.head(of: worktree)
        try fixture.write(".env", "SECRET=1\n", in: worktree)
        try fixture.write("feature.txt", "changed\n", in: worktree)

        assertRefused(await makeExecutor().execute(request(mode: .manualStashed))) { $0 == .ignoredFiles(1, paths: [".env"]) }
        XCTAssertEqual(try stashList(), "", "Nothing was stashed")
        XCTAssertEqual(try String(contentsOfFile: worktree + "/feature.txt", encoding: .utf8), "changed\n")

        try FileManager.default.removeItem(atPath: worktree + "/.env")
        try fixture.git(["update-index", "--skip-worktree", "README.md"], in: worktree)
        assertRefused(await makeExecutor().execute(request(mode: .manualStashed))) { $0 == .hiddenIndexEntries(1) }
        XCTAssertEqual(try stashList(), "")
    }

    func testNothingIsStashedWithoutConsentOrWhenThereIsNothingToSave() async throws {
        try fixture.write("feature.txt", "changed\n", in: worktree)
        live.value = settings(consent: false)
        assertRefused(await makeExecutor().execute(request(mode: .manualStashed))) { $0 == .cleanupConsentMissing }
        XCTAssertEqual(try stashList(), "")

        live.value = settings()
        try fixture.git(["checkout", "--", "feature.txt"], in: worktree)
        assertRefused(await makeExecutor().execute(request(mode: .manualStashed))) { if case .expectationChanged = $0 { true } else { false } }
        XCTAssertEqual(try stashList(), "")
    }

    func testThePrimaryWorktreeIsNeverStashed() async throws {
        try fixture.write("README.md", "primary change\n")
        let outcome = await makeExecutor().execute(request(path: fixture.repositoryPath, expectedHead: try fixture.head(), mode: .manualStashed))
        guard case .refused = outcome else { return XCTFail("Expected refusal, got \(outcome)") }
        XCTAssertEqual(try stashList(), "")
        XCTAssertEqual(try String(contentsOfFile: fixture.repositoryPath + "/README.md", encoding: .utf8), "primary change\n")
    }

    /// After stashing, the removal still runs every local check; a refusal says where the changes are.
    func testAFileAppearingAfterTheStashStopsRemovalAndTheStashIsReported() async throws {
        try makeChanges()
        let late = worktree + "/late.txt"
        live.setOnRead { read, _ in
            // Read 5 is the last settings check after the stash, right before the final inspection.
            if read == 5 { try? "late\n".write(toFile: late, atomically: true, encoding: .utf8) }
        }
        let outcome = await makeExecutor().execute(request(mode: .manualStashed))
        guard case .refused(let entry, let reasons) = outcome else { return XCTFail("Expected refusal, got \(outcome)") }
        let stash = try XCTUnwrap(entry.stashCommit)
        XCTAssertEqual(reasons.first, .changesStashed(stash))
        XCTAssertTrue(reasons.contains(.untrackedFiles(1)), "\(reasons)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: late))
        XCTAssertTrue(try stashList().contains(stash))
        XCTAssertEqual(try fixture.git(["show", "\(stash):feature.txt"]), "changed")
    }

    /// A Git wrapper that logs every call and can fake `stash push` (success without saving anything).
    private func loggingGit(fakeStashPush: Bool = false, refuseRemoval: Bool = false) throws -> (GitClient, String) {
        let script = fixture.root + "/logging-git.sh"
        let log = fixture.root + "/git-calls.log"
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log)'
        prev=""
        for arg in "$@"; do
          if [ "\(fakeStashPush)" = "true" ] && [ "$prev" = "stash" ] && [ "$arg" = "push" ]; then
            echo "Saved working directory and index state (pretend)"
            exit 0
          fi
          if [ "\(refuseRemoval)" = "true" ] && [ "$prev" = "worktree" ] && [ "$arg" = "remove" ]; then
            echo "fatal: simulated refusal" >&2
            exit 128
          fi
          prev="$arg"
        done
        exec /usr/bin/git "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
        return (GitClient(executableURL: URL(fileURLWithPath: script), environment: TemporaryGitRepository.isolatedEnvironment), log)
    }

    func testAStashThatCannotBeConfirmedStopsBeforeRemoval() async throws {
        // An older stash on the same HEAD must not be mistaken for the one this attempt should have made.
        try fixture.write("feature.txt", "older work\n", in: worktree)
        try fixture.write("older.txt", "older untracked\n", in: worktree)
        try fixture.git(["stash", "push", "--include-untracked", "--message", "older work"], in: worktree)
        try makeChanges()
        let (git, _) = try loggingGit(fakeStashPush: true)
        assertRefused(await makeExecutor(git: git).execute(request(mode: .manualStashed))) { if case .stashNotConfirmed = $0 { true } else { false } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/notes/todo.txt"), "Nothing was touched")
        XCTAssertEqual(try String(contentsOfFile: worktree + "/feature.txt", encoding: .utf8), "changed\n")
    }

    func testStashUsesOnlySafeArgumentsAndAGitRefusalAfterwardsKeepsTheStash() async throws {
        try makeChanges()
        let (git, log) = try loggingGit(refuseRemoval: true)
        let outcome = await makeExecutor(git: git).execute(request(mode: .manualStashed))
        guard case .failed(let entry) = outcome else { return XCTFail("Expected failure, got \(outcome)") }
        let stash = try XCTUnwrap(entry.stashCommit)
        XCTAssertTrue(try stashList().contains(stash))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))

        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let pushes = calls.filter { $0.contains(" stash push ") }
        XCTAssertEqual(pushes.count, 1)
        XCTAssertTrue(pushes[0].hasPrefix("-C \(worktree!) -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false stash push --include-untracked --message WCleaner "), pushes[0])
        for forbidden in ["--all", " -a ", "stash drop", "stash pop", "stash clear", "--force", " clean", "branch -D", "prune"] {
            XCTAssertFalse(calls.contains { $0.contains(forbidden) }, "Never \(forbidden)")
        }
        XCTAssertEqual(calls.filter { $0.contains("worktree remove") }.count, 1, "No retry after a refusal")
    }

    func testHooksDoNotRunWhileStashing() async throws {
        let marker = fixture.root + "/hook-ran"
        let hooks = try fixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"]) + "/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: hooks + "/reference-transaction", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hooks + "/reference-transaction")
        try fixture.write("feature.txt", "changed\n", in: worktree)

        let outcome = await makeExecutor().execute(request(mode: .manualStashed))
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "The repository's hooks did not run")
    }

    // MARK: Disposable ignored files

    private func commitGitignore() throws {
        try fixture.write(".gitignore", "build/\n.env\n", in: worktree)
        try fixture.git(["add", ".gitignore"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Ignore"], in: worktree)
        head = try fixture.head(of: worktree)
        evidence.set(evidence: .success(pullRequest()))
    }

    func testIgnoredFilesMarkedDisposableAreRemovedWithTheWorktree() async throws {
        try commitGitignore()
        try fixture.write("build/output.bin", "x", in: worktree)
        // Only the registry's record counts, not the copy in the request.
        try await registry.update(id: repository.id) { $0.disposableIgnoredPaths = ["build"] }

        let outcome = await makeExecutor().execute(request())
        guard case .removed(let entry) = outcome else { return XCTFail("Expected removal, got \(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        XCTAssertTrue(entry.rationale.contains { $0.contains("marked disposable") && $0.contains("build/") }, "\(entry.rationale)")
    }

    func testIgnoredFileNotMarkedDisposableStillBlocksRemoval() async throws {
        try commitGitignore()
        try fixture.write("build/output.bin", "x", in: worktree)
        try fixture.write(".env", "SECRET=1\n", in: worktree)
        try await registry.update(id: repository.id) { $0.disposableIgnoredPaths = ["build"] }

        assertRefused(await makeExecutor().execute(request())) { $0 == .ignoredFiles(1, paths: [".env"]) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/.env"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/build/output.bin"))
    }

    /// The last check uses the repository's list as it is then, not as it was when the check started.
    func testDisposablePathWithdrawnJustBeforeRemovalBlocksIt() async throws {
        try commitGitignore()
        try fixture.write("build/output.bin", "x", in: worktree)
        try await registry.update(id: repository.id) { $0.disposableIgnoredPaths = ["build"] }
        let registry = self.registry!, live = self.live!, id = repository.id
        let reads = ReadCounter()
        let executor = makeExecutor(settings: {
            // The third read happens after the deep inspection, right before the final check.
            if await reads.next() == 3 {
                try? await registry.update(id: id) { $0.disposableIgnoredPaths = [] }
            }
            return live.read()
        })

        assertRefused(await executor.execute(request())) { if case .ignoredFiles = $0 { true } else { false } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/build/output.bin"))
    }

    func testLockedWorktreeBlocksRemoval() async throws {
        try fixture.git(["worktree", "lock", "--reason", "in use", worktree])
        assertRefused(await makeExecutor().execute(request())) { if case .locked = $0 { return true }; return false }
    }

    func testOperationInProgressBlocksRemoval() async throws {
        let gitDirectory = try fixture.git(["rev-parse", "--path-format=absolute", "--git-dir"], in: worktree)
        try "\(head!)\n".write(toFile: gitDirectory + "/MERGE_HEAD", atomically: true, encoding: .utf8)
        assertRefused(await makeExecutor().execute(request())) { if case .operationInProgress = $0 { return true }; return false }
    }

    func testPrimaryWorktreeIsNeverRemoved() async throws {
        let outcome = await makeExecutor().execute(request(path: fixture.repositoryPath, expectedHead: try fixture.head()))
        guard case .refused(_, let reasons) = outcome else { return XCTFail("Expected refusal, got \(outcome)") }
        XCTAssertTrue(reasons.contains(.primaryWorktree))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repositoryPath + "/README.md"))
    }

    // MARK: Head and pull request evidence

    func testNewLocalCommitAfterEvaluationBlocksRemoval() async throws {
        let evaluatedHead = head!
        try fixture.write("more.txt", "more\n", in: worktree)
        try fixture.git(["add", "more.txt"], in: worktree)
        try fixture.git(["commit", "-q", "-m", "Unpublished"], in: worktree)
        assertRefused(await makeExecutor().execute(request(expectedHead: evaluatedHead))) { if case .expectationChanged = $0 { return true }; return false }
    }

    func testPullRequestHeadDifferentFromLocalHeadBlocksRemoval() async {
        evidence.set(evidence: .success(pullRequest(head: EligibilityFixture.otherHead)))
        assertRefused(await makeExecutor().execute(request())) { if case .headDiffersFromPullRequest = $0 { return true }; return false }
    }

    func testOpenOrClosedPullRequestBlocksRemoval() async {
        evidence.set(evidence: .success(pullRequest(state: .open)))
        assertRefused(await makeExecutor().execute(request())) { if case .pullRequestOpen = $0 { return true }; return false }
        evidence.set(evidence: .success(pullRequest(state: .closedUnmerged)))
        assertRefused(await makeExecutor().execute(request())) { if case .pullRequestClosedUnmerged = $0 { return true }; return false }
    }

    func testRemoteErrorsBlockRemoval() async {
        for error in [GitHubAPIError.unauthorized, .forbidden(""), .notFound, .network("offline"), .rateLimited(resetAt: nil)] {
            evidence.set(evidence: .failure(error))
            assertRefused(await makeExecutor().execute(request())) { if case .pullRequestLookupFailed = $0 { return true }; return false }
        }
    }

    func testUnverifiedAccountBlocksRemoval() async {
        evidence.set(resolution: RepositoryResolution(resolution: .accountUnavailable(account, reason: "Reconnect"), githubRepository: nil, remotes: [], githubRemotes: [:]))
        assertRefused(await makeExecutor().execute(request())) { if case .accountUnavailable = $0 { return true }; return false }
        evidence.set(resolution: RepositoryResolution(resolution: .needsSelection([account]), githubRepository: nil, remotes: [], githubRemotes: [:]))
        assertRefused(await makeExecutor().execute(request())) { $0 == .needsAccountSelection }
    }

    func testMergedBeforeEnrollmentNeedsReviewThenApprovalAllowsRemoval() async {
        evidence.set(evidence: .success(pullRequest(mergedAt: enrolledAt.addingTimeInterval(-86_400))))
        assertRefused(await makeExecutor().execute(request())) { if case .mergedBeforeEnrollment = $0 { return true }; return false }

        await tracking.approve(WorktreeKey(repositoryID: repository.id, path: worktree), pullRequest: 12, head: head, now: now)
        let outcome = await makeExecutor().execute(request())
        XCTAssertTrue(outcome.didRemove, "\(outcome)")
    }

    // MARK: Policy gates

    func testDevelopmentBuildPolicyNeverRemoves() async {
        assertRefused(await makeExecutor(allowRemoval: false).execute(request())) { $0 == .deletionDisabledInDevelopmentBuild }
    }

    func testDebugPolicyRequiresExplicitOptIn() {
        #if DEBUG
        XCTAssertFalse(DeletionPolicy.forCurrentBuild(environment: [:]).allowsRealRemoval)
        XCTAssertTrue(DeletionPolicy.forCurrentBuild(environment: ["WCLEANER_ALLOW_REMOVAL_IN_DEBUG": "1"]).allowsRealRemoval)
        #endif
    }

    func testConsentIsRequired() async {
        live.value = settings(consent: false)
        assertRefused(await makeExecutor().execute(request())) { $0 == .cleanupConsentMissing }
    }

    func testAutomaticModeHonorsOffPausedAndDelay() async {
        live.value = settings(auto: false)
        assertRefused(await makeExecutor().execute(request(mode: .automatic))) { $0 == .automaticCleanupOff }
        live.value = settings(paused: true)
        assertRefused(await makeExecutor().execute(request(mode: .automatic))) { $0 == .automaticCleanupPaused }
        live.value = settings(delay: .oneHour)
        assertRefused(await makeExecutor().execute(request(mode: .automatic))) { if case .waitingForDelay = $0 { return true }; return false }
    }

    /// The executor reads the settings three times: on entry, for the decision after the fresh evidence,
    /// and right before `git worktree remove`. A change at any of them stops the removal.
    func testPauseDuringVerificationStopsAutomaticRemoval() async {
        for pauseAtRead in 2...3 {
            live.value = settings()
            live.setOnRead { read, settings in if read >= pauseAtRead { settings.autoCleanupPaused = true } }
            assertRefused(await makeExecutor().execute(request(mode: .automatic))) { $0 == .automaticCleanupPaused }
        }
    }

    func testConsentWithdrawnDuringVerificationStopsManualRemoval() async {
        live.setOnRead { read, settings in if read >= 3 { settings.cleanupConsentAt = nil } }
        assertRefused(await makeExecutor().execute(request())) { $0 == .cleanupConsentMissing }
    }

    func testRepositoryRemovedFromWCleanerIsRefused() async throws {
        try await registry.remove(id: repository.id)
        assertRefused(await makeExecutor().execute(request())) { if case .expectationChanged = $0 { return true }; return false }
    }

    func testRepositoryRecordThatNoLongerMatchesIsRefused() async {
        var moved = repository!
        moved.path = fixture.root + "/elsewhere"
        let outcome = await makeExecutor().execute(CleanupRequest(
            repository: moved,
            worktreePath: worktree,
            expectedHead: head,
            expectedPullRequest: 12,
            expectedHeadRepositoryFullName: "octo/repo",
            mode: .manual,
            estimatedSizeBytes: nil
        ))
        assertRefused(outcome) { if case .expectationChanged = $0 { return true }; return false }
    }

    func testWorktreeNoLongerListedIsRefused() async {
        assertRefused(await makeExecutor().execute(request(path: fixture.root + "/does-not-exist"))) { $0 == .worktreeNoLongerListed }
    }

    func testConcurrentCleanupOfTheSameRepositoryIsRefused() async {
        let executor = makeExecutor()
        let evidence = self.evidence!
        let firstRequest = request()
        evidence.holdNextCall()
        let first = Task { await executor.execute(firstRequest) }
        await waitUntil { evidence.entered == 1 }

        let second = await executor.execute(request())
        guard case .refused(_, let reasons) = second else { return XCTFail("Expected refusal, got \(second)") }
        XCTAssertEqual(reasons, [.anotherCleanupInProgress])

        evidence.release()
        let firstOutcome = await first.value
        XCTAssertTrue(firstOutcome.didRemove, "\(firstOutcome)")
    }

    // MARK: Git refusal

    /// A Git wrapper that refuses `worktree remove` and logs every invocation.
    private func refusingGit() throws -> (GitClient, String) {
        let script = fixture.root + "/refusing-git.sh"
        let log = fixture.root + "/git-invocations.log"
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log)'
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "worktree" ] && [ "$arg" = "remove" ]; then
            echo "fatal: simulated refusal" >&2
            exit 128
          fi
          prev="$arg"
        done
        exec /usr/bin/git "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
        let client = GitClient(executableURL: URL(fileURLWithPath: script), environment: TemporaryGitRepository.isolatedEnvironment)
        return (client, log)
    }

    func testGitRefusalIsFinalAndNeverRetriedWithForce() async throws {
        let (git, log) = try refusingGit()
        let outcome = await makeExecutor(git: git).execute(request())
        guard case .failed(let entry) = outcome else { return XCTFail("Expected failure, got \(outcome)") }
        XCTAssertTrue(entry.errorMessage?.contains("simulated refusal") ?? false, entry.errorMessage ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))

        let invocations = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
        let removals = invocations.filter { $0.contains("worktree remove") }
        XCTAssertEqual(removals.count, 1, "No retry after a refusal")
        XCTAssertEqual(removals.first.map(String.init), "-C \(fixture.repositoryPath) worktree remove -- \(worktree!)")
        XCTAssertFalse(invocations.contains { $0.contains("--force") || $0.split(separator: " ").contains("-f") })
        XCTAssertFalse(invocations.contains { $0.contains("clean") || $0.contains("branch -D") || $0.contains("prune") })
    }
}

private actor ReadCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
