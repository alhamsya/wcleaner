import Foundation

/// Something the app may tell the user about (through notifications).
public enum MonitorEvent: Sendable, Equatable {
    case cleanupCompleted(CleanupOutcome)
    /// A worktree became ready for review (merged before enrollment) for the first time.
    case reviewRequired(repositoryName: String, worktreePath: String, pullRequest: Int)
    case accountNeedsReconnect(login: String)
}

public enum MonitorActionError: Error, LocalizedError, Equatable {
    case worktreeNotFound
    /// The worktree's pull request or HEAD is no longer what the user saw and confirmed.
    case stateChanged
    case notAwaitingReview
    case notSafeToRemove([EligibilityReason])
    case cleanupUnavailable

    public var errorDescription: String? {
        switch self {
        case .worktreeNotFound: "The worktree is no longer listed. Run Check Now and try again."
        case .stateChanged: "The worktree changed since you looked at it (a different pull request or commit). Nothing was done; review it again."
        case .notAwaitingReview: "This worktree is not waiting for a review."
        case .notSafeToRemove(let reasons):
            "The worktree is not safe to remove: " + (reasons.first?.message ?? "the safety checks did not pass.")
        case .cleanupUnavailable: "Cleanup is not available in this build."
        }
    }
}

/// Fresh evidence from the live services, used by the cleanup executor immediately before removal.
public struct LiveCleanupEvidence: CleanupEvidenceProviding {
    private let git: GitClient
    private let resolver: RepositoryAccountResolver
    private let matcher: PullRequestMatcher
    private let accounts: GitHubAccountStore

    public init(git: GitClient, resolver: RepositoryAccountResolver, matcher: PullRequestMatcher, accounts: GitHubAccountStore) {
        self.git = git
        self.resolver = resolver
        self.matcher = matcher
        self.accounts = accounts
    }

    public func freshResolution(for repository: RegisteredRepository) async -> RepositoryResolution {
        do {
            let remotes = try await git.remotes(repositoryPath: repository.path)
            return await resolver.resolve(repository, remotes: remotes, cachePolicy: .fresh, allowDiscovery: false)
        } catch {
            return RepositoryResolution(resolution: .unverified(error.userMessage), remotes: [], githubRemotes: [:])
        }
    }

    public func freshPullRequest(
        number: Int,
        base: ResolvedGitHubRepository,
        account: AccountID,
        expectedHeadRepositoryFullName: String?
    ) async throws -> PullRequestEvidence {
        try await matcher.freshEvidence(
            number: number,
            baseRepository: base,
            account: account,
            expectedHeadRepositoryFullName: expectedHeadRepositoryFullName
        )
    }

    public func accountLogin(_ id: AccountID) async -> String? {
        await accounts.account(id)?.login
    }
}

/// Runs scans: lists worktrees, inspects them, resolves accounts and pull requests and produces
/// fail-closed decisions. All work is serialized, so scans, reviews and removals never interleave.
/// With automatic cleanup active it hands eligible worktrees to the executor, which re-verifies
/// everything from scratch before removing anything.
public actor MonitorEngine {
    /// Upper bound on automatic removals per scan; the rest wait for the next scan.
    public static let maximumAutomaticRemovalsPerScan = 10

    private let registry: RepositoryRegistry
    private let git: GitClient
    private let scanner: WorktreeScanner
    private let inspector: WorktreeInspector
    private let resolver: RepositoryAccountResolver
    private let matcher: PullRequestMatcher
    private let api: GitHubAPIClient
    private let accounts: GitHubAccountStore
    private let tracking: WorktreeTrackingStore
    private let diskUsage: DiskUsageService
    private let history: CleanupHistoryStore
    private let executor: (any CleanupExecuting)?
    private let liveSettings: (@Sendable () async -> AppSettings)?
    private let evaluator = CleanupEligibilityEvaluator()
    private let now: @Sendable () -> Date

    private var snapshot = MonitorSnapshot.empty
    private var snapshotObserver: (@Sendable (MonitorSnapshot) -> Void)?
    private var eventObserver: (@Sendable (MonitorEvent) -> Void)?
    private var lastSettings: AppSettings?
    private var reportedReviews: Set<WorktreeKey> = []
    private var reportedReconnects: Set<AccountID> = []
    private var diskTask: Task<Void, Never>?

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(
        registry: RepositoryRegistry,
        git: GitClient,
        resolver: RepositoryAccountResolver,
        matcher: PullRequestMatcher,
        api: GitHubAPIClient,
        accounts: GitHubAccountStore,
        tracking: WorktreeTrackingStore,
        diskUsage: DiskUsageService,
        history: CleanupHistoryStore,
        executor: (any CleanupExecuting)?,
        liveSettings: (@Sendable () async -> AppSettings)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.registry = registry
        self.git = git
        self.scanner = WorktreeScanner(git: git)
        self.inspector = WorktreeInspector(git: git)
        self.resolver = resolver
        self.matcher = matcher
        self.api = api
        self.accounts = accounts
        self.tracking = tracking
        self.diskUsage = diskUsage
        self.history = history
        self.executor = executor
        self.liveSettings = liveSettings
        self.now = now
    }

    public func setSnapshotObserver(_ observer: @escaping @Sendable (MonitorSnapshot) -> Void) {
        snapshotObserver = observer
        observer(snapshot)
    }

    public func setEventObserver(_ observer: @escaping @Sendable (MonitorEvent) -> Void) {
        eventObserver = observer
    }

    public func currentSnapshot() -> MonitorSnapshot { snapshot }

    public func setNextScan(_ date: Date?) {
        snapshot.nextScanAt = date
        publish()
    }

    // MARK: Scanning

    /// Scans every registered repository (or only `repositoryIDs`) and returns how the remote lookups went.
    @discardableResult
    public func scan(trigger: ScanTrigger, settings: AppSettings, repositoryIDs: Set<UUID>? = nil) async -> ScanOutcome {
        await acquire()
        defer { release() }
        return await performScan(settings: settings, repositoryIDs: repositoryIDs)
    }

    private func performScan(settings: AppSettings, repositoryIDs: Set<UUID>?) async -> ScanOutcome {
        lastSettings = settings
        let repositories = await registry.all()
        snapshot.isScanning = true
        snapshot.lastScanStartedAt = now()
        publish()

        var stats = LookupStats()
        var updated: [UUID: RepositorySnapshot] = Dictionary(snapshot.repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for repository in repositories {
            if let repositoryIDs, !repositoryIDs.contains(repository.id) { continue }
            if Task.isCancelled { break }
            updated[repository.id] = await scanRepository(repository, settings: settings, stats: &stats)
        }

        let known = Set(repositories.map(\.id))
        snapshot.repositories = repositories.compactMap { updated[$0.id] }.filter { known.contains($0.id) }
        snapshot.isScanning = false
        snapshot.lastScanCompletedAt = now()
        snapshot.lastScanError = stats.summaryError
        publish()
        reportNewEvents()
        scheduleDiskMeasurement()

        let outcome = await stats.outcome(api: api, now: now())
        if settings.automaticCleanupActive, executor != nil {
            await runAutomaticCleanup(settings: settings)
        }
        return outcome
    }

    private func scanRepository(_ repository: RegisteredRepository, settings: AppSettings, stats: inout LookupStats) async -> RepositorySnapshot {
        var result = RepositorySnapshot(repository: repository)
        let records: [WorktreeRecord]
        do {
            records = try await scanner.scan(repository)
        } catch {
            result.error = error.userMessage
            result.accountResolution = .unverified("The repository could not be read.")
            return result
        }
        result.primaryWorktreePath = records.first?.path

        let remotes: [GitRemote]
        do {
            remotes = try await git.remotes(repositoryPath: repository.path)
        } catch {
            remotes = []
            result.error = "Remotes could not be read: \(error.userMessage)"
        }
        let resolution = await resolver.resolve(repository, remotes: remotes)
        result.accountResolution = resolution.resolution
        result.githubRepository = resolution.githubRepository
        stats.recordResolution(resolution.resolution)
        if let account = resolution.resolution.assignedAccount {
            result.accountLogin = await accounts.account(account)?.login
        }
        let upstreams = (try? await git.branchUpstreams(repositoryPath: repository.path)) ?? [:]

        let policy = CleanupPolicySettings(settings)
        let allPaths = records.map(\.path)
        var worktrees: [WorktreeSnapshot] = []
        for (index, record) in records.enumerated() {
            let isPrimary = index == 0
            let key = WorktreeKey(repositoryID: repository.id, path: record.path)
            let inspection: LocalWorktreeInspection? = isPrimary
                ? nil
                : await inspector.inspect(record: record, commonDirectory: repository.commonDirectory, depth: .standard, now: now())

            var match: PullRequestMatch?
            if !isPrimary,
               case .assigned(let account, _) = resolution.resolution,
               let github = resolution.githubRepository,
               let branch = record.branchName,
               let head = record.head {
                let found = await matcher.match(PullRequestLookup(
                    baseRepository: github,
                    account: account,
                    localBranch: branch,
                    localHead: head,
                    upstream: upstreams[branch],
                    githubRemotes: resolution.githubRemotes
                ))
                stats.recordMatch(found, account: account)
                match = found
            }

            var input = EligibilityInput(
                repository: repository,
                record: record,
                isPrimary: isPrimary,
                allWorktreePaths: allPaths,
                commonDirectory: repository.commonDirectory,
                inspection: inspection,
                githubRepository: resolution.githubRepository,
                account: resolution.resolution,
                pullRequest: match,
                tracking: nil,
                settings: policy,
                now: now(),
                requireDeepInspection: false
            )
            let decision: CleanupDecision
            if isPrimary {
                decision = evaluator.evaluate(input)
            } else {
                (decision, input.inspection) = await decideLinked(input, key: key)
            }
            let usage: DiskUsageValue = isPrimary ? .unknown : await diskUsage.value(for: record.path)
            worktrees.append(WorktreeSnapshot(
                repositoryID: repository.id,
                record: record,
                isPrimary: isPrimary,
                pullRequest: match,
                decision: decision,
                diskUsage: usage,
                inspection: input.inspection
            ))
        }
        result.worktrees = worktrees
        await tracking.prune(repositoryID: repository.id, keeping: Set(allPaths))
        return result
    }

    /// Decides a linked worktree the way the executor would: one that looks removable also gets the deep
    /// checks (index flags, submodules, per-worktree refs, nested `.git` entries), so the dry run never shows
    /// "Safe to remove" for a worktree the executor would refuse. Deep results already present are reused.
    private func decideLinked(_ input: EligibilityInput, key: WorktreeKey) async -> (CleanupDecision, LocalWorktreeInspection?) {
        var input = input
        var preliminary = input
        preliminary.tracking = await tracking.tracking(for: key)
        if evaluator.evaluate(preliminary).isSafeToRemove {
            if !(input.inspection?.hasDeepResults ?? false) {
                input.inspection = await inspector.inspect(record: input.record, commonDirectory: input.commonDirectory, depth: .deep, now: now())
            }
            input.requireDeepInspection = true
        }
        return (await tracking.decide(input, key: key, evaluator: evaluator).decision, input.inspection)
    }

    // MARK: Automatic cleanup

    private func runAutomaticCleanup(settings: AppSettings) async {
        guard let executor else { return }
        let candidates = snapshot.repositories.flatMap { repository in
            repository.linkedWorktrees
                .filter { $0.decision.automaticCleanupAllowed && $0.decision.evidence != nil }
                .map { (repository, $0) }
        }
        guard !candidates.isEmpty else { return }
        var touched: Set<UUID> = []
        for (repository, worktree) in candidates.prefix(Self.maximumAutomaticRemovalsPerScan) {
            if Task.isCancelled { break }
            // Pause, Off or withdrawn consent during the scan stops the batch (the executor checks again).
            if let liveSettings, !(await liveSettings()).automaticCleanupActive { break }
            guard let request = makeRequest(repository: repository, worktree: worktree, mode: .automatic) else { continue }
            let outcome = await executor.execute(request)
            touched.insert(repository.id)
            emit(.cleanupCompleted(outcome))
            if outcome.didRemove { await diskUsage.invalidate(worktree.path) }
        }
        if !touched.isEmpty {
            var stats = LookupStats()
            for id in touched {
                guard let repository = await registry.repository(id) else { continue }
                let refreshed = await scanRepository(repository, settings: settings, stats: &stats)
                replace(refreshed)
            }
            publish()
        }
    }

    private func makeRequest(repository: RepositorySnapshot, worktree: WorktreeSnapshot, mode: CleanupMode) -> CleanupRequest? {
        guard let evidence = worktree.decision.evidence, let head = worktree.head else { return nil }
        return CleanupRequest(
            repository: repository.repository,
            worktreePath: worktree.path,
            expectedHead: head,
            expectedPullRequest: evidence.number,
            expectedHeadRepositoryFullName: evidence.headRepositoryVerified ? evidence.headRepositoryFullName : nil,
            githubRepositoryFullName: repository.githubRepository?.fullName,
            mode: mode,
            estimatedSizeBytes: worktree.diskUsage.bytes
        )
    }

    // MARK: User actions

    /// Records an explicit review of a worktree merged before enrollment. The approval is bound to the
    /// exact pull request number and head SHA the user saw; a different PR or a new commit needs a new review.
    public func approveReview(
        repositoryID: UUID,
        worktreePath: String,
        expectedPullRequest: Int,
        expectedHead: String,
        settings: AppSettings
    ) async throws {
        await acquire()
        defer { release() }
        guard let found = find(repositoryID: repositoryID, path: worktreePath) else {
            throw MonitorActionError.worktreeNotFound
        }
        let (repository, worktree) = found
        guard worktree.decision.verdict == .needsReview, let evidence = worktree.decision.evidence, let head = worktree.head, evidence.headSHA == head else {
            throw MonitorActionError.notAwaitingReview
        }
        guard evidence.number == expectedPullRequest, head == expectedHead else {
            throw MonitorActionError.stateChanged
        }
        let key = WorktreeKey(repositoryID: repositoryID, path: worktreePath)
        await tracking.approve(key, pullRequest: evidence.number, head: head, now: now())
        let login = repository.accountLogin
        try? await history.append(CleanupHistoryEntry(
            timestamp: now(),
            mode: .manual,
            result: .reviewed,
            repositoryName: repository.repository.displayName,
            repositoryPath: repository.repository.path,
            githubRepository: repository.githubRepository?.fullName,
            worktreePath: worktreePath,
            branch: worktree.branch,
            headSHA: head,
            pullRequestNumber: evidence.number,
            pullRequestURL: evidence.url,
            accountLogin: login,
            accountID: evidence.accountID.storageKey,
            rationale: ["Reviewed and allowed for cleanup: pull request #\(evidence.number) was merged before WCleaner started monitoring this repository."],
            errorMessage: nil,
            estimatedSizeBytes: worktree.diskUsage.bytes
        ))
        reportedReviews.remove(key)
        await rescan(repositoryID, settings: settings)
    }

    /// Removes one worktree now, on the user's explicit confirmation. The executor re-runs every check.
    public func removeWorktree(
        repositoryID: UUID,
        worktreePath: String,
        expectedPullRequest: Int,
        expectedHead: String,
        settings: AppSettings
    ) async throws -> CleanupOutcome {
        await acquire()
        defer { release() }
        guard let executor else { throw MonitorActionError.cleanupUnavailable }
        guard let found = find(repositoryID: repositoryID, path: worktreePath) else {
            throw MonitorActionError.worktreeNotFound
        }
        let (repository, worktree) = found
        guard worktree.decision.isSafeToRemove,
              let request = makeRequest(repository: repository, worktree: worktree, mode: .manual) else {
            throw MonitorActionError.notSafeToRemove(worktree.decision.blockingReasons)
        }
        guard request.expectedPullRequest == expectedPullRequest, request.expectedHead == expectedHead else {
            throw MonitorActionError.stateChanged
        }
        let outcome = await executor.execute(request)
        if outcome.didRemove { await diskUsage.invalidate(worktreePath) }
        emit(.cleanupCompleted(outcome))
        await rescan(repositoryID, settings: settings)
        return outcome
    }

    /// The account mapping of a repository changed: earlier merge confirmations no longer count.
    public func accountMappingChanged(repositoryID: UUID, settings: AppSettings) async {
        await acquire()
        defer { release() }
        await tracking.invalidateConfirmations(repositoryID: repositoryID)
        await rescan(repositoryID, settings: settings)
    }

    public func repositoryRemoved(_ repositoryID: UUID) async {
        await acquire()
        defer { release() }
        if let removed = snapshot.repositories.first(where: { $0.id == repositoryID }) {
            for worktree in removed.worktrees { await diskUsage.invalidate(worktree.path) }
        }
        snapshot.repositories.removeAll { $0.id == repositoryID }
        reportedReviews = reportedReviews.filter { $0.repositoryID != repositoryID }
        await tracking.removeRepository(repositoryID)
        publish()
    }

    /// Re-measures linked worktree sizes in the background (`force` ignores the one-hour cache).
    public func refreshDiskUsage(force: Bool) {
        scheduleDiskMeasurement(force: force)
    }

    /// Re-evaluates decisions with new settings (consent, delay, pause) without touching the network.
    /// Worktrees that become removable get the local deep checks first, as in a scan.
    public func settingsChanged(_ settings: AppSettings) async {
        await acquire()
        defer { release() }
        lastSettings = settings
        let policy = CleanupPolicySettings(settings)
        for repositoryIndex in snapshot.repositories.indices {
            let repository = snapshot.repositories[repositoryIndex]
            let paths = repository.worktrees.map(\.path)
            for worktreeIndex in repository.worktrees.indices {
                let worktree = repository.worktrees[worktreeIndex]
                let key = WorktreeKey(repositoryID: repository.id, path: worktree.path)
                let input = EligibilityInput(
                    repository: repository.repository,
                    record: worktree.record,
                    isPrimary: worktree.isPrimary,
                    allWorktreePaths: paths,
                    commonDirectory: repository.repository.commonDirectory,
                    inspection: worktree.inspection,
                    githubRepository: repository.githubRepository,
                    account: repository.accountResolution,
                    pullRequest: worktree.pullRequest,
                    tracking: nil,
                    settings: policy,
                    now: now(),
                    requireDeepInspection: false
                )
                if worktree.isPrimary {
                    snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].decision = evaluator.evaluate(input)
                } else {
                    let (decision, inspection) = await decideLinked(input, key: key)
                    snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].decision = decision
                    snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].inspection = inspection
                }
            }
        }
        publish()
    }

    // MARK: Helpers

    private func rescan(_ repositoryID: UUID, settings: AppSettings) async {
        guard let repository = await registry.repository(repositoryID) else {
            snapshot.repositories.removeAll { $0.id == repositoryID }
            publish()
            return
        }
        var stats = LookupStats()
        let refreshed = await scanRepository(repository, settings: settings, stats: &stats)
        replace(refreshed)
        publish()
        scheduleDiskMeasurement()
    }

    private func replace(_ repository: RepositorySnapshot) {
        if let index = snapshot.repositories.firstIndex(where: { $0.id == repository.id }) {
            snapshot.repositories[index] = repository
        } else {
            snapshot.repositories.append(repository)
        }
    }

    private func find(repositoryID: UUID, path: String) -> (RepositorySnapshot, WorktreeSnapshot)? {
        guard let repository = snapshot.repositories.first(where: { $0.id == repositoryID }),
              let worktree = repository.linkedWorktrees.first(where: { $0.path == path }) else { return nil }
        return (repository, worktree)
    }

    private func scheduleDiskMeasurement(force: Bool = false) {
        let paths = snapshot.allLinkedWorktrees.map(\.path)
        let service = diskUsage
        diskTask?.cancel()
        guard !paths.isEmpty else {
            Task { await service.removeAll(except: []) }
            return
        }
        diskTask = Task(priority: .background) { [weak self] in
            await service.removeAll(except: Set(paths))
            var stale: [String] = []
            for path in paths {
                if force {
                    stale.append(path)
                } else if await service.isStale(path) {
                    stale.append(path)
                }
            }
            guard !stale.isEmpty, !Task.isCancelled else { return }
            let values = await service.measure(stale, force: force)
            guard !Task.isCancelled else { return }
            await self?.applyDiskUsage(values)
        }
    }

    private func applyDiskUsage(_ values: [String: DiskUsageValue]) {
        var changed = false
        for repositoryIndex in snapshot.repositories.indices {
            for worktreeIndex in snapshot.repositories[repositoryIndex].worktrees.indices {
                let path = snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].path
                if let value = values[path], snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].diskUsage != value {
                    snapshot.repositories[repositoryIndex].worktrees[worktreeIndex].diskUsage = value
                    changed = true
                }
            }
        }
        if changed { publish() }
    }

    private func reportNewEvents() {
        var currentReviews: Set<WorktreeKey> = []
        for repository in snapshot.repositories {
            for worktree in repository.linkedWorktrees where worktree.decision.verdict == .needsReview {
                let key = WorktreeKey(repositoryID: repository.id, path: worktree.path)
                currentReviews.insert(key)
                if !reportedReviews.contains(key), let number = worktree.decision.evidence?.number {
                    emit(.reviewRequired(repositoryName: repository.repository.displayName, worktreePath: worktree.path, pullRequest: number))
                }
            }
        }
        reportedReviews = currentReviews

        Task { [weak self] in await self?.reportReconnects() }
    }

    private func reportReconnects() async {
        let all = await accounts.all()
        var current: Set<AccountID> = []
        for account in all where !account.state.isConnected {
            current.insert(account.id)
            if !reportedReconnects.contains(account.id) {
                emit(.accountNeedsReconnect(login: account.login))
            }
        }
        reportedReconnects = current
    }

    private func emit(_ event: MonitorEvent) {
        eventObserver?(event)
    }

    private func publish() {
        snapshotObserver?(snapshot)
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Tallies remote lookups during a scan to choose the scheduler's next delay.
struct LookupStats {
    var attempted = 0
    var failed = 0
    var accounts: Set<AccountID> = []
    var firstError: String?

    mutating func recordResolution(_ resolution: AccountResolution) {
        switch resolution {
        case .assigned(let account, _):
            attempted += 1
            accounts.insert(account)
        case .unverified(let detail):
            attempted += 1
            failed += 1
            if firstError == nil { firstError = detail }
        case .needsSelection, .needsAccount, .accountUnavailable, .notGitHub:
            break
        }
    }

    mutating func recordMatch(_ match: PullRequestMatch, account: AccountID) {
        attempted += 1
        accounts.insert(account)
        if case .unavailable(let detail) = match {
            failed += 1
            if firstError == nil { firstError = detail }
        }
    }

    var summaryError: String? {
        guard failed > 0 else { return nil }
        if failed == attempted { return "GitHub could not be reached: \(firstError ?? "unknown error")" }
        return nil
    }

    func outcome(api: GitHubAPIClient, now: Date) async -> ScanOutcome {
        var latestReset: Date?
        for account in accounts {
            if let reset = await api.rateLimitReset(for: account) {
                latestReset = max(latestReset ?? reset, reset)
            }
        }
        if let latestReset, failed > 0 { return .rateLimited(until: latestReset) }
        if attempted == 0 || failed == 0 { return .success }
        return failed == attempted ? .networkFailure : .partialFailure
    }
}
