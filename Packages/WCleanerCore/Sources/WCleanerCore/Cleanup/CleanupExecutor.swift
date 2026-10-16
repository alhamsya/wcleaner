import Foundation

public struct CleanupRequest: Sendable, Equatable {
    public var repository: RegisteredRepository
    public var worktreePath: String
    public var expectedHead: String
    public var expectedPullRequest: Int
    /// The head repository seen when the worktree was evaluated; fresh evidence must agree.
    public var expectedHeadRepositoryFullName: String?
    /// For the audit log only.
    public var githubRepositoryFullName: String?
    public var mode: CleanupMode
    public var estimatedSizeBytes: Int64?

    public init(
        repository: RegisteredRepository,
        worktreePath: String,
        expectedHead: String,
        expectedPullRequest: Int,
        expectedHeadRepositoryFullName: String?,
        githubRepositoryFullName: String? = nil,
        mode: CleanupMode,
        estimatedSizeBytes: Int64?
    ) {
        self.repository = repository
        self.worktreePath = worktreePath
        self.expectedHead = expectedHead
        self.expectedPullRequest = expectedPullRequest
        self.expectedHeadRepositoryFullName = expectedHeadRepositoryFullName
        self.githubRepositoryFullName = githubRepositoryFullName
        self.mode = mode
        self.estimatedSizeBytes = estimatedSizeBytes
    }
}

public enum CleanupOutcome: Sendable, Equatable {
    case removed(CleanupHistoryEntry)
    case refused(CleanupHistoryEntry, [EligibilityReason])
    case failed(CleanupHistoryEntry)

    public var entry: CleanupHistoryEntry {
        switch self {
        case .removed(let entry), .refused(let entry, _), .failed(let entry): entry
        }
    }

    public var didRemove: Bool {
        if case .removed = self { return true }
        return false
    }
}

public protocol CleanupExecuting: Sendable {
    func execute(_ request: CleanupRequest) async -> CleanupOutcome
}

/// Fresh, uncached evidence used immediately before removal.
public protocol CleanupEvidenceProviding: Sendable {
    func freshResolution(for repository: RegisteredRepository) async -> RepositoryResolution
    func freshPullRequest(
        number: Int,
        base: ResolvedGitHubRepository,
        account: AccountID,
        expectedHeadRepositoryFullName: String?
    ) async throws -> PullRequestEvidence
    func accountLogin(_ id: AccountID) async -> String?
}

/// Whether this build may actually remove anything. Debug builds default to dry-run only, so developing
/// WCleaner can never touch real repositories; tests opt in explicitly with disposable fixtures.
public struct DeletionPolicy: Sendable, Equatable {
    public var allowsRealRemoval: Bool

    public init(allowsRealRemoval: Bool) {
        self.allowsRealRemoval = allowsRealRemoval
    }

    public static func forCurrentBuild(environment: [String: String] = ProcessInfo.processInfo.environment) -> DeletionPolicy {
        #if DEBUG
        DeletionPolicy(allowsRealRemoval: environment["WCLEANER_ALLOW_REMOVAL_IN_DEBUG"] == "1")
        #else
        DeletionPolicy(allowsRealRemoval: true)
        #endif
    }
}

/// Performs a single removal with every safety check re-run from scratch. Order matters:
/// fresh remote evidence first, then the deep local inspection, then `git worktree remove` without
/// `--force`. A refusal from Git is final; nothing is ever retried with force or deleted any other way.
public actor CleanupExecutor: CleanupExecuting {
    private let git: GitClient
    private let scanner: WorktreeScanner
    private let inspector: WorktreeInspector
    private let evidence: any CleanupEvidenceProviding
    private let tracking: WorktreeTrackingStore
    private let evaluator: CleanupEligibilityEvaluator
    private let history: CleanupHistoryStore
    private let policy: DeletionPolicy
    private let registry: RepositoryRegistry
    private let currentSettings: @Sendable () async -> AppSettings
    private let now: @Sendable () -> Date
    private var inFlight: Set<UUID> = []

    /// - Parameter settings: the user's settings as they are right now (not as they were when a scan
    ///   started), read again immediately before removal so Pause or withdrawn consent always wins.
    public init(
        git: GitClient,
        evidence: any CleanupEvidenceProviding,
        tracking: WorktreeTrackingStore,
        history: CleanupHistoryStore,
        registry: RepositoryRegistry,
        policy: DeletionPolicy,
        settings: @escaping @Sendable () async -> AppSettings,
        evaluator: CleanupEligibilityEvaluator = CleanupEligibilityEvaluator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.git = git
        self.scanner = WorktreeScanner(git: git)
        self.inspector = WorktreeInspector(git: git)
        self.evidence = evidence
        self.tracking = tracking
        self.evaluator = evaluator
        self.history = history
        self.registry = registry
        self.policy = policy
        self.currentSettings = settings
        self.now = now
    }

    public func execute(_ request: CleanupRequest) async -> CleanupOutcome {
        guard !inFlight.contains(request.repository.id) else {
            return await refuse(request, [.anotherCleanupInProgress])
        }
        inFlight.insert(request.repository.id)
        defer { inFlight.remove(request.repository.id) }

        guard policy.allowsRealRemoval else {
            return await refuse(request, [.deletionDisabledInDevelopmentBuild])
        }
        if let reason = await settingsBlocker(for: request.mode) {
            return await refuse(request, [reason])
        }
        // 0. The repository must still be enrolled, unchanged. Its stored record is authoritative.
        guard let repository = await enrolledRepository(matching: request.repository) else {
            return await refuse(request, [.expectationChanged("The repository is no longer monitored by WCleaner, or its location changed.")])
        }

        // 1. Git must still list exactly this worktree, at the expected HEAD.
        let records: [WorktreeRecord]
        do {
            records = try await scanner.scan(repository)
        } catch {
            return await refuse(request, [.statusUnavailable(error.userMessage)])
        }
        guard let index = records.firstIndex(where: { $0.path == request.worktreePath }) else {
            return await refuse(request, [.worktreeNoLongerListed])
        }
        let record = records[index]
        guard record.head == request.expectedHead else {
            return await refuse(request, [.expectationChanged("HEAD moved since the last check.")], record: record)
        }

        // 2. Fresh remote evidence: the existing account assignment and the pull request, bypassing every cache.
        let resolution = await evidence.freshResolution(for: repository)
        var pullRequest: PullRequestMatch = .unavailable("The account or repository could not be verified.")
        var accountLogin: String?
        if case .assigned(let accountID, _) = resolution.resolution, let github = resolution.githubRepository {
            accountLogin = await evidence.accountLogin(accountID)
            do {
                let fresh = try await evidence.freshPullRequest(
                    number: request.expectedPullRequest,
                    base: github,
                    account: accountID,
                    expectedHeadRepositoryFullName: request.expectedHeadRepositoryFullName
                )
                pullRequest = .matched(fresh)
            } catch {
                pullRequest = .unavailable(error.userMessage)
            }
        }

        // 3. Deep local inspection, then the decision with the settings as they are now.
        let inspection = await inspector.inspect(record: record, commonDirectory: repository.commonDirectory, depth: .deep, now: now())
        let settings = await currentSettings()
        var input = EligibilityInput(
            repository: repository,
            record: record,
            isPrimary: index == 0,
            allWorktreePaths: records.map(\.path),
            commonDirectory: repository.commonDirectory,
            inspection: inspection,
            githubRepository: resolution.githubRepository,
            account: resolution.resolution,
            pullRequest: pullRequest,
            tracking: nil,
            settings: CleanupPolicySettings(settings),
            now: now(),
            requireDeepInspection: true
        )
        let (decision, decidedTracking) = await tracking.decide(input, key: WorktreeKey(repositoryID: repository.id, path: record.path), evaluator: evaluator)

        let allowed = request.mode == .automatic ? decision.automaticCleanupAllowed : decision.isSafeToRemove
        guard allowed else {
            let reasons = decision.reasons.filter { $0.kind != .info }
            return await refuse(request, reasons.isEmpty ? decision.reasons : reasons, record: record, evidence: decision.evidence, accountLogin: accountLogin)
        }
        guard let evidence = decision.evidence, evidence.number == request.expectedPullRequest, inspection.headSHA == request.expectedHead else {
            return await refuse(request, [.expectationChanged("The pull request or HEAD changed during verification.")], record: record)
        }

        // 4. Last look, as close to the removal as possible: settings, enrollment, and every local check
        //    again (status with ignored files, index flags, per-worktree refs, nested .git entries,
        //    operations in progress). Git's own check in `worktree remove` covers none of these.
        if let reason = await settingsBlocker(for: request.mode) {
            return await refuse(request, [reason], record: record, evidence: evidence, accountLogin: accountLogin)
        }
        guard await enrolledRepository(matching: request.repository) != nil else {
            return await refuse(request, [.expectationChanged("The repository was removed from WCleaner during verification.")], record: record)
        }
        input.inspection = await inspector.inspect(record: record, commonDirectory: repository.commonDirectory, depth: .deep, now: now())
        input.tracking = decidedTracking
        let final = evaluator.evaluate(input)
        guard final.isSafeToRemove, input.inspection?.headSHA == request.expectedHead else {
            return await refuse(
                request,
                [.expectationChanged("The worktree changed during verification.")] + final.blockingReasons,
                record: record,
                evidence: evidence,
                accountLogin: accountLogin
            )
        }

        // 5. Remove with Git only. No --force, no rm -rf, no git clean, no branch deletion.
        let rationale = Self.rationale(evidence: evidence, accountLogin: accountLogin)
        do {
            try await git.removeWorktree(repositoryPath: repository.path, worktreePath: record.path)
        } catch {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale + ["Git refused to remove the worktree; WCleaner does not retry with --force."], error: error.userMessage)
        }

        // 6. Confirm the result.
        if FileManager.default.fileExists(atPath: record.path) {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: "Git reported success but the folder still exists.")
        }
        let remaining = try? await scanner.scan(repository)
        if let remaining, remaining.contains(where: { $0.path == record.path }) {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: "Git still lists the worktree after removal.")
        }
        if let remaining {
            await tracking.prune(repositoryID: repository.id, keeping: Set(remaining.map(\.path)))
        }
        return await finish(.removed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: nil)
    }

    /// Why the current settings forbid this removal, if they do.
    private func settingsBlocker(for mode: CleanupMode) async -> EligibilityReason? {
        let settings = await currentSettings()
        guard settings.hasCleanupConsent else { return .cleanupConsentMissing }
        if mode == .automatic {
            if !settings.autoCleanupEnabled { return .automaticCleanupOff }
            if settings.autoCleanupPaused { return .automaticCleanupPaused }
        }
        return nil
    }

    /// The registry's current record of the repository, only if it still matches what was evaluated.
    private func enrolledRepository(matching expected: RegisteredRepository) async -> RegisteredRepository? {
        guard let stored = await registry.repository(expected.id),
              stored.path == expected.path,
              stored.commonDirectory == expected.commonDirectory,
              stored.isBare == expected.isBare,
              stored.pullRequestRemote == expected.pullRequestRemote else { return nil }
        return stored
    }

    static func rationale(evidence: PullRequestEvidence, accountLogin: String?) -> [String] {
        var lines = [
            "Pull request #\(evidence.number) is merged\(evidence.mergedAt.map { " (\(EnglishDateFormat.dateTime.format($0)))" } ?? "").",
            "Worktree HEAD \(evidence.headSHA.prefix(12)) equals the pull request head.",
            "No staged, unstaged, untracked or ignored files; no hidden index entries, per-worktree refs or nested .git folders; no submodules; no operation in progress.",
        ]
        if let accountLogin {
            lines.append("Verified with GitHub account @\(accountLogin).")
        }
        return lines
    }

    private func refuse(
        _ request: CleanupRequest,
        _ reasons: [EligibilityReason],
        record: WorktreeRecord? = nil,
        evidence: PullRequestEvidence? = nil,
        accountLogin: String? = nil
    ) async -> CleanupOutcome {
        let entry = makeEntry(request, result: .refused, record: record, evidence: evidence, accountLogin: accountLogin, rationale: reasons.map(\.message), error: nil)
        try? await history.append(entry)
        return .refused(entry, reasons)
    }

    private func finish(
        _ result: CleanupResult,
        request: CleanupRequest,
        record: WorktreeRecord,
        evidence: PullRequestEvidence,
        accountLogin: String?,
        rationale: [String],
        error: String?
    ) async -> CleanupOutcome {
        let entry = makeEntry(request, result: result, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: error)
        try? await history.append(entry)
        return result == .removed ? .removed(entry) : .failed(entry)
    }

    private func makeEntry(
        _ request: CleanupRequest,
        result: CleanupResult,
        record: WorktreeRecord?,
        evidence: PullRequestEvidence?,
        accountLogin: String?,
        rationale: [String],
        error: String?
    ) -> CleanupHistoryEntry {
        CleanupHistoryEntry(
            timestamp: now(),
            mode: request.mode,
            result: result,
            repositoryName: request.repository.displayName,
            repositoryPath: request.repository.path,
            githubRepository: request.githubRepositoryFullName,
            worktreePath: request.worktreePath,
            branch: record?.branchName,
            headSHA: record?.head ?? request.expectedHead,
            pullRequestNumber: evidence?.number ?? request.expectedPullRequest,
            pullRequestURL: evidence?.url,
            accountLogin: accountLogin,
            accountID: evidence?.accountID.storageKey,
            rationale: rationale,
            errorMessage: error,
            estimatedSizeBytes: request.estimatedSizeBytes
        )
    }
}
