import Foundation

/// Persists per-worktree policy state: when a merge was first confirmed (for the cleanup delay) and
/// explicit review approvals. Writes to disk only when something changed.
public actor WorktreeTrackingStore {
    private struct Entry: Codable {
        let key: WorktreeKey
        let tracking: WorktreeTracking
    }

    private let store: JSONFileStore<[Entry]>
    private var entries: [WorktreeKey: WorktreeTracking]

    public init(directory: AppDataDirectory, fileName: String = "worktree-tracking.json") {
        self.store = JSONFileStore(directory: directory, fileName: fileName)
        let loaded = (try? store.load()) ?? []
        self.entries = Dictionary(loaded.map { ($0.key, $0.tracking) }, uniquingKeysWith: { first, _ in first })
    }

    public func tracking(for key: WorktreeKey) -> WorktreeTracking? {
        entries[key]
    }

    /// Updates merge confirmation from this scan's pull request result and returns the current tracking.
    /// Unknown results (lookup failures) keep the previous confirmation so a flaky network does not restart
    /// the delay; any positive evidence of a different state clears it. A confirmation is recorded only while
    /// every other check passes (`otherwiseEligible`), so the cleanup delay is a grace period that starts when
    /// the worktree became safe to remove, not when the merge happened.
    @discardableResult
    public func observe(
        _ key: WorktreeKey,
        match: PullRequestMatch?,
        localHead: String?,
        otherwiseEligible: Bool = true,
        now: Date
    ) -> WorktreeTracking {
        var tracking = entries[key] ?? WorktreeTracking(firstSeenAt: now)
        switch match {
        case .matched(let evidence) where evidence.state == .merged && evidence.mergedAt != nil && evidence.headSHA == localHead:
            if !otherwiseEligible {
                tracking.mergeConfirmedAt = nil
                tracking.confirmedPullRequest = nil
                tracking.confirmedHead = nil
                tracking.confirmedAccount = nil
            } else if !tracking.confirms(evidence) {
                tracking.mergeConfirmedAt = now
                tracking.confirmedPullRequest = evidence.number
                tracking.confirmedHead = evidence.headSHA
                tracking.confirmedAccount = evidence.accountID
            }
        case .unavailable, .none:
            break
        default:
            tracking.mergeConfirmedAt = nil
            tracking.confirmedPullRequest = nil
            tracking.confirmedHead = nil
            tracking.confirmedAccount = nil
        }
        if entries[key] != tracking {
            entries[key] = tracking
            persist()
        }
        return tracking
    }

    /// Evaluates a worktree and keeps its merge confirmation in step with the result: first without a new
    /// confirmation, then, if every other check passes, with one. Used by both the scan and the executor.
    public func decide(
        _ input: EligibilityInput,
        key: WorktreeKey,
        evaluator: CleanupEligibilityEvaluator = CleanupEligibilityEvaluator()
    ) -> (decision: CleanupDecision, tracking: WorktreeTracking) {
        var input = input
        input.tracking = entries[key]
        let preliminary = evaluator.evaluate(input)
        let updated = observe(key, match: input.pullRequest, localHead: input.record.head, otherwiseEligible: preliminary.isSafeToRemove, now: input.now)
        input.tracking = updated
        return (evaluator.evaluate(input), updated)
    }

    public func approve(_ key: WorktreeKey, pullRequest: Int, head: String, now: Date) {
        var tracking = entries[key] ?? WorktreeTracking(firstSeenAt: now)
        tracking.reviewApproval = ReviewApproval(approvedAt: now, pullRequestNumber: pullRequest, headSHA: head)
        entries[key] = tracking
        persist()
    }

    /// Forgets merge confirmations for a repository (for example after its account mapping changed),
    /// so the cleanup delay starts again from fresh evidence.
    public func invalidateConfirmations(repositoryID: UUID) {
        var changed = false
        for (key, var tracking) in entries where key.repositoryID == repositoryID && tracking.mergeConfirmedAt != nil {
            tracking.mergeConfirmedAt = nil
            tracking.confirmedPullRequest = nil
            tracking.confirmedHead = nil
            tracking.confirmedAccount = nil
            entries[key] = tracking
            changed = true
        }
        if changed { persist() }
    }

    public func removeRepository(_ repositoryID: UUID) {
        let before = entries.count
        entries = entries.filter { $0.key.repositoryID != repositoryID }
        if entries.count != before { persist() }
    }

    /// Drops entries for worktrees of `repositoryID` that Git no longer lists.
    public func prune(repositoryID: UUID, keeping paths: Set<String>) {
        let before = entries.count
        entries = entries.filter { $0.key.repositoryID != repositoryID || paths.contains($0.key.path) }
        if entries.count != before { persist() }
    }

    private func persist() {
        let list = entries.map { Entry(key: $0.key, tracking: $0.value) }
            .sorted { ($0.key.repositoryID.uuidString, $0.key.path) < ($1.key.repositoryID.uuidString, $1.key.path) }
        try? store.save(list)
    }
}
