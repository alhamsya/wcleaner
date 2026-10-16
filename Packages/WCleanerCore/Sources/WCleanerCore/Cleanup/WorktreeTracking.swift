import Foundation

/// Identifies a worktree within a registered repository.
public struct WorktreeKey: Hashable, Codable, Sendable {
    public let repositoryID: UUID
    public let path: String

    public init(repositoryID: UUID, path: String) {
        self.repositoryID = repositoryID
        self.path = path
    }
}

/// The user's explicit approval for one specific worktree state (PR + HEAD).
public struct ReviewApproval: Codable, Sendable, Equatable {
    public var approvedAt: Date
    public var pullRequestNumber: Int
    public var headSHA: String

    public init(approvedAt: Date, pullRequestNumber: Int, headSHA: String) {
        self.approvedAt = approvedAt
        self.pullRequestNumber = pullRequestNumber
        self.headSHA = headSHA
    }
}

/// Persisted per-worktree state used by the cleanup policy.
public struct WorktreeTracking: Codable, Sendable, Equatable {
    public var firstSeenAt: Date
    /// When WCleaner first verified the merge for `confirmedPullRequest` at `confirmedHead`.
    public var mergeConfirmedAt: Date?
    public var confirmedPullRequest: Int?
    public var confirmedHead: String?
    public var confirmedAccount: AccountID?
    public var reviewApproval: ReviewApproval?

    public init(
        firstSeenAt: Date,
        mergeConfirmedAt: Date? = nil,
        confirmedPullRequest: Int? = nil,
        confirmedHead: String? = nil,
        confirmedAccount: AccountID? = nil,
        reviewApproval: ReviewApproval? = nil
    ) {
        self.firstSeenAt = firstSeenAt
        self.mergeConfirmedAt = mergeConfirmedAt
        self.confirmedPullRequest = confirmedPullRequest
        self.confirmedHead = confirmedHead
        self.confirmedAccount = confirmedAccount
        self.reviewApproval = reviewApproval
    }

    /// True when the stored merge confirmation refers to exactly this evidence.
    public func confirms(_ evidence: PullRequestEvidence) -> Bool {
        mergeConfirmedAt != nil
            && confirmedPullRequest == evidence.number
            && confirmedHead == evidence.headSHA
            && confirmedAccount == evidence.accountID
    }

    public func approves(pullRequest number: Int, head: String) -> Bool {
        guard let approval = reviewApproval else { return false }
        return approval.pullRequestNumber == number && approval.headSHA == head
    }
}
