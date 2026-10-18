import Foundation

public struct CleanupRequest: Sendable, Equatable {
    public var repository: RegisteredRepository
    public var worktreePath: String
    public var expectedHead: String
    /// The merged pull request the user or the scan saw. Nil only for `.manualUnmerged`.
    public var expectedPullRequest: Int?
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
        expectedPullRequest: Int?,
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
        switch request.mode {
        case .manualUnmerged:
            return await removeWithoutMergedPullRequest(
                request,
                repository: repository,
                record: record,
                isPrimary: index == 0,
                allWorktreePaths: records.map(\.path)
            )
        case .manualStashed:
            return await stashChangesAndRemove(
                request,
                repository: repository,
                record: record,
                isPrimary: index == 0,
                allWorktreePaths: records.map(\.path)
            )
        case .manual, .automatic:
            break
        }
        guard let expectedPullRequest = request.expectedPullRequest else {
            return await refuse(request, [.expectationChanged("No merged pull request was given for this removal.")], record: record)
        }

        // 2. Fresh remote evidence: the existing account assignment and the pull request, bypassing every cache.
        let resolution = await evidence.freshResolution(for: repository)
        var pullRequest: PullRequestMatch = .unavailable("The account or repository could not be verified.")
        var accountLogin: String?
        if case .assigned(let accountID, _) = resolution.resolution, let github = resolution.githubRepository {
            accountLogin = await evidence.accountLogin(accountID)
            do {
                let fresh = try await evidence.freshPullRequest(
                    number: expectedPullRequest,
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
        guard let evidence = decision.evidence, evidence.number == expectedPullRequest, inspection.headSHA == request.expectedHead else {
            return await refuse(request, [.expectationChanged("The pull request or HEAD changed during verification.")], record: record)
        }

        // 4. Last look, as close to the removal as possible: settings, enrollment, and every local check
        //    again (status with ignored files, index flags, per-worktree refs, nested .git entries,
        //    operations in progress). Git's own check in `worktree remove` covers none of these.
        if let reason = await settingsBlocker(for: request.mode) {
            return await refuse(request, [reason], record: record, evidence: evidence, accountLogin: accountLogin)
        }
        guard let latest = await enrolledRepository(matching: request.repository) else {
            return await refuse(request, [.expectationChanged("The repository was removed from WCleaner during verification.")], record: record)
        }
        // The repository's settings as they are now (a path taken off the disposable list must count).
        input.repository = latest
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

        let rationale = Self.rationale(evidence: evidence, accountLogin: accountLogin, disposableIgnoredPaths: Self.disposablePaths(in: final))
        return await removeAndConfirm(request, repository: repository, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale)
    }

    /// Removal the user asked for although the pull request is not merged (open, closed, missing or not
    /// verifiable). No GitHub evidence is needed: `git worktree remove` keeps the branch and its commits.
    /// Every structural and local check must pass, with the deep checks, twice, exactly as for a merged
    /// worktree; any pull request, account or policy reason is the only thing waived.
    private func removeWithoutMergedPullRequest(
        _ request: CleanupRequest,
        repository: RegisteredRepository,
        record: WorktreeRecord,
        isPrimary: Bool,
        allWorktreePaths: [String],
        stash: StashCommit? = nil
    ) async -> CleanupOutcome {
        // Once changes were stashed, every refusal says where they are.
        let saved: [EligibilityReason] = stash.map { [.changesStashed($0.sha)] } ?? []

        // 3. Deep local inspection and the local part of the decision.
        let (decision, inspection) = await localDecision(repository: repository, record: record, isPrimary: isPrimary, allWorktreePaths: allWorktreePaths)
        guard decision.localChecksPassed, inspection.headSHA == request.expectedHead else {
            let reasons = decision.localBlockingReasons ?? []
            return await refuse(request, saved + (reasons.isEmpty ? [.expectationChanged("HEAD moved during verification.")] : reasons), record: record, stash: stash?.sha)
        }

        // 4. Last look: settings, enrollment (with the repository's settings as they are now), every local check.
        if let reason = await settingsBlocker(for: request.mode) {
            return await refuse(request, saved + [reason], record: record, stash: stash?.sha)
        }
        guard let latest = await enrolledRepository(matching: request.repository) else {
            return await refuse(request, saved + [.expectationChanged("The repository was removed from WCleaner during verification.")], record: record, stash: stash?.sha)
        }
        let (final, finalInspection) = await localDecision(repository: latest, record: record, isPrimary: isPrimary, allWorktreePaths: allWorktreePaths)
        guard final.localChecksPassed, finalInspection.headSHA == request.expectedHead else {
            return await refuse(
                request,
                saved + [.expectationChanged("The worktree changed during verification.")] + (final.localBlockingReasons ?? []),
                record: record,
                stash: stash?.sha
            )
        }

        var rationale: [String]
        if let stash {
            rationale = [
                "Removed at your request after saving its uncommitted changes in Git stash \(stash.sha.prefix(12)) (“\(stash.subject)”).",
                "Restore them in any worktree of this repository with “git stash apply \(stash.sha)”.",
            ]
        } else {
            rationale = ["Removed at your request without a merged pull request."]
        }
        rationale += [
            "The branch “\(record.branchName ?? "?")” and its commits stay in the repository; HEAD was \(request.expectedHead.prefix(12)).",
            Self.localRationale(disposableIgnoredPaths: Self.disposablePaths(in: final)),
        ]
        rationale += Self.disposableRationale(Self.disposablePaths(in: final))
        return await removeAndConfirm(request, repository: latest, record: record, evidence: nil, accountLogin: nil, rationale: rationale, stash: stash?.sha)
    }

    /// Saves the worktree's uncommitted changes in a new stash, confirms that Git holds them there, then
    /// removes the worktree as `removeWithoutMergedPullRequest` does. Nothing is changed unless every other
    /// local check passes first, and nothing is removed unless the stash is confirmed. The stash lives in the
    /// repository (`refs/stash` is shared by all worktrees), so it survives the removal.
    private func stashChangesAndRemove(
        _ request: CleanupRequest,
        repository: RegisteredRepository,
        record: WorktreeRecord,
        isPrimary: Bool,
        allWorktreePaths: [String]
    ) async -> CleanupOutcome {
        // 3a. Before changing anything: the only local reasons may be changes that a stash saves completely.
        let (before, inspection) = await localDecision(repository: repository, record: record, isPrimary: isPrimary, allWorktreePaths: allWorktreePaths)
        guard inspection.headSHA == request.expectedHead else {
            return await refuse(request, [.expectationChanged("HEAD moved since the last check.")], record: record)
        }
        guard let local = before.localBlockingReasons else {
            return await refuse(request, [.statusUnavailable("The local checks did not complete.")], record: record)
        }
        let unsaveable = local.filter { !$0.isStashable }
        guard unsaveable.isEmpty else {
            return await refuse(request, unsaveable, record: record)
        }
        guard !local.isEmpty else {
            return await refuse(request, [.expectationChanged("It has no uncommitted changes anymore. Check again, then use Remove Worktree Anyway.")], record: record)
        }
        if let reason = await settingsBlocker(for: request.mode) {
            return await refuse(request, [reason], record: record)
        }
        guard await enrolledRepository(matching: request.repository) != nil else {
            return await refuse(request, [.expectationChanged("The repository was removed from WCleaner during verification.")], record: record)
        }

        // 3b. Save the changes in a new stash and confirm it: new, marked with this attempt's token, made on HEAD,
        //     and with the untracked-files commit when there were untracked files.
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let marker = Self.stashMarker(token)
        let previous: StashCommit?
        do {
            previous = try await git.latestStash(worktreePath: record.path)
        } catch {
            return await refuse(request, [.statusUnavailable(error.userMessage)], record: record)
        }
        do {
            try await git.stashPush(worktreePath: record.path, message: Self.stashMessage(marker: marker, worktreePath: record.path, branch: record.branchName))
        } catch {
            var saved: StashCommit?
            if let latest = try? await git.latestStash(worktreePath: record.path), latest.subject.contains(marker) {
                saved = latest
            }
            return await finish(
                .failed,
                request: request,
                record: record,
                evidence: nil,
                accountLogin: nil,
                rationale: ["Git could not save the uncommitted changes in a stash, so nothing was removed."]
                    + (saved.map { [EligibilityReason.changesStashed($0.sha).message] } ?? []),
                error: error.userMessage,
                stash: saved?.sha
            )
        }
        let stash: StashCommit
        do {
            guard let latest = try await git.latestStash(worktreePath: record.path),
                  latest.sha != previous?.sha,
                  latest.subject.contains(marker) else {
                return await refuse(request, [.stashNotConfirmed("Git did not create the expected stash.")], record: record)
            }
            stash = latest
        } catch {
            return await refuse(request, [.stashNotConfirmed(error.userMessage)], record: record)
        }
        let hadUntracked = (inspection.status?.untrackedCount ?? 0) > 0
        guard stash.parents.first == request.expectedHead, stash.parents.count >= 2, !hadUntracked || stash.parents.count == 3 else {
            return await refuse(
                request,
                [.stashNotConfirmed("Stash \(stash.sha.prefix(12)) is not based on the worktree's HEAD as expected."), .changesStashed(stash.sha)],
                record: record,
                stash: stash.sha
            )
        }

        // 4. Removal as without a merged pull request: every local check, twice, on the now clean worktree.
        return await removeWithoutMergedPullRequest(
            request,
            repository: repository,
            record: record,
            isPrimary: isPrimary,
            allWorktreePaths: allWorktreePaths,
            stash: stash
        )
    }

    static func stashMarker(_ token: String) -> String { "WCleaner \(token):" }

    /// One line; Git prefixes it with "On <branch>: ".
    static func stashMessage(marker: String, worktreePath: String, branch: String?) -> String {
        let name = (worktreePath as NSString).lastPathComponent
        let text = "\(marker) saved before removing worktree \(name)" + (branch.map { " (branch \($0))" } ?? "")
        return String(text.map { $0.isNewline ? " " : $0 })
    }

    /// The decision for the local checks only, from a fresh deep inspection and the settings as they are now.
    private func localDecision(
        repository: RegisteredRepository,
        record: WorktreeRecord,
        isPrimary: Bool,
        allWorktreePaths: [String]
    ) async -> (CleanupDecision, LocalWorktreeInspection) {
        let inspection = await inspector.inspect(record: record, commonDirectory: repository.commonDirectory, depth: .deep, now: now())
        let settings = await currentSettings()
        let input = EligibilityInput(
            repository: repository,
            record: record,
            isPrimary: isPrimary,
            allWorktreePaths: allWorktreePaths,
            commonDirectory: repository.commonDirectory,
            inspection: inspection,
            githubRepository: nil,
            account: .unverified("Not needed to remove a worktree without a merged pull request."),
            pullRequest: nil,
            tracking: nil,
            settings: CleanupPolicySettings(settings),
            now: now(),
            requireDeepInspection: true
        )
        return (evaluator.evaluate(input), inspection)
    }

    /// 5. Remove with Git only (no --force, no rm -rf, no git clean, no branch deletion), then 6. confirm.
    private func removeAndConfirm(
        _ request: CleanupRequest,
        repository: RegisteredRepository,
        record: WorktreeRecord,
        evidence: PullRequestEvidence?,
        accountLogin: String?,
        rationale: [String],
        stash: String? = nil
    ) async -> CleanupOutcome {
        do {
            try await git.removeWorktree(repositoryPath: repository.path, worktreePath: record.path)
        } catch {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale + ["Git refused to remove the worktree; WCleaner does not retry with --force."], error: error.userMessage, stash: stash)
        }
        if FileManager.default.fileExists(atPath: record.path) {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: "Git reported success but the folder still exists.", stash: stash)
        }
        let remaining = try? await scanner.scan(repository)
        if let remaining, remaining.contains(where: { $0.path == record.path }) {
            return await finish(.failed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: "Git still lists the worktree after removal.", stash: stash)
        }
        if let remaining {
            await tracking.prune(repositoryID: repository.id, keeping: Set(remaining.map(\.path)))
        }
        return await finish(.removed, request: request, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: nil, stash: stash)
    }

    private static func disposablePaths(in decision: CleanupDecision) -> [String] {
        decision.reasons.compactMap { reason -> [String]? in
            if case .disposableIgnoredFiles(let paths) = reason { paths } else { nil }
        }.flatMap { $0 }
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

    static func rationale(evidence: PullRequestEvidence, accountLogin: String?, disposableIgnoredPaths: [String] = []) -> [String] {
        var lines = [
            "Pull request #\(evidence.number) is merged\(evidence.mergedAt.map { " (\(EnglishDateFormat.dateTime.format($0)))" } ?? "").",
            "Worktree HEAD \(evidence.headSHA.prefix(12)) equals the pull request head.",
            localRationale(disposableIgnoredPaths: disposableIgnoredPaths),
        ]
        lines += disposableRationale(disposableIgnoredPaths)
        if let accountLogin {
            lines.append("Verified with GitHub account @\(accountLogin).")
        }
        return lines
    }

    static func localRationale(disposableIgnoredPaths: [String]) -> String {
        disposableIgnoredPaths.isEmpty
            ? "No staged, unstaged, untracked or ignored files; no hidden index entries, per-worktree refs or nested .git folders; no checked-out submodules; no operation in progress."
            : "No staged, unstaged or untracked files; no hidden index entries, per-worktree refs or nested .git folders; no checked-out submodules; no operation in progress."
    }

    static func disposableRationale(_ paths: [String]) -> [String] {
        paths.isEmpty ? [] : ["Deleted ignored files marked disposable for this repository: \(EligibilityReason.list(paths, limit: 20))."]
    }

    private func refuse(
        _ request: CleanupRequest,
        _ reasons: [EligibilityReason],
        record: WorktreeRecord? = nil,
        evidence: PullRequestEvidence? = nil,
        accountLogin: String? = nil,
        stash: String? = nil
    ) async -> CleanupOutcome {
        let entry = makeEntry(request, result: .refused, record: record, evidence: evidence, accountLogin: accountLogin, rationale: reasons.map(\.message), error: nil, stash: stash)
        try? await history.append(entry)
        return .refused(entry, reasons)
    }

    private func finish(
        _ result: CleanupResult,
        request: CleanupRequest,
        record: WorktreeRecord,
        evidence: PullRequestEvidence?,
        accountLogin: String?,
        rationale: [String],
        error: String?,
        stash: String? = nil
    ) async -> CleanupOutcome {
        let entry = makeEntry(request, result: result, record: record, evidence: evidence, accountLogin: accountLogin, rationale: rationale, error: error, stash: stash)
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
        error: String?,
        stash: String?
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
            estimatedSizeBytes: request.estimatedSizeBytes,
            stashCommit: stash
        )
    }
}
