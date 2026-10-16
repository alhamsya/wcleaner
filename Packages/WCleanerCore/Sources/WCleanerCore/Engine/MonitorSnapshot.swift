import Foundation

/// Display state of one linked worktree, produced by a scan.
public struct WorktreeSnapshot: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var repositoryID: UUID
    public var record: WorktreeRecord
    public var isPrimary: Bool
    public var pullRequest: PullRequestMatch?
    public var decision: CleanupDecision
    public var diskUsage: DiskUsageValue
    public var inspection: LocalWorktreeInspection?

    public init(
        repositoryID: UUID,
        record: WorktreeRecord,
        isPrimary: Bool,
        pullRequest: PullRequestMatch?,
        decision: CleanupDecision,
        diskUsage: DiskUsageValue,
        inspection: LocalWorktreeInspection?
    ) {
        self.repositoryID = repositoryID
        self.record = record
        self.isPrimary = isPrimary
        self.pullRequest = pullRequest
        self.decision = decision
        self.diskUsage = diskUsage
        self.inspection = inspection
    }

    public var path: String { record.path }
    public var name: String { (record.path as NSString).lastPathComponent }
    public var branch: String? { record.branchName }
    public var head: String? { record.head }
    public var shortHead: String { head.map { String($0.prefix(7)) } ?? "unknown" }
}

/// Display state of one registered repository.
public struct RepositorySnapshot: Sendable, Identifiable, Equatable {
    public var id: UUID { repository.id }
    public var repository: RegisteredRepository
    public var githubRepository: ResolvedGitHubRepository?
    public var accountResolution: AccountResolution
    public var accountLogin: String?
    public var primaryWorktreePath: String?
    public var worktrees: [WorktreeSnapshot]
    public var error: String?

    public init(
        repository: RegisteredRepository,
        githubRepository: ResolvedGitHubRepository? = nil,
        accountResolution: AccountResolution = .unverified("Not checked yet."),
        accountLogin: String? = nil,
        primaryWorktreePath: String? = nil,
        worktrees: [WorktreeSnapshot] = [],
        error: String? = nil
    ) {
        self.repository = repository
        self.githubRepository = githubRepository
        self.accountResolution = accountResolution
        self.accountLogin = accountLogin
        self.primaryWorktreePath = primaryWorktreePath
        self.worktrees = worktrees
        self.error = error
    }

    public var linkedWorktrees: [WorktreeSnapshot] { worktrees.filter { !$0.isPrimary } }
}

/// The whole monitoring state shown in the menu and Settings.
public struct MonitorSnapshot: Sendable, Equatable {
    public var repositories: [RepositorySnapshot]
    public var lastScanStartedAt: Date?
    public var lastScanCompletedAt: Date?
    public var nextScanAt: Date?
    public var isScanning: Bool
    public var lastScanError: String?

    public init(
        repositories: [RepositorySnapshot] = [],
        lastScanStartedAt: Date? = nil,
        lastScanCompletedAt: Date? = nil,
        nextScanAt: Date? = nil,
        isScanning: Bool = false,
        lastScanError: String? = nil
    ) {
        self.repositories = repositories
        self.lastScanStartedAt = lastScanStartedAt
        self.lastScanCompletedAt = lastScanCompletedAt
        self.nextScanAt = nextScanAt
        self.isScanning = isScanning
        self.lastScanError = lastScanError
    }

    public static let empty = MonitorSnapshot()

    public var allLinkedWorktrees: [WorktreeSnapshot] { repositories.flatMap(\.linkedWorktrees) }

    /// Estimated size of every linked worktree.
    public var totalUsage: DiskUsageTotal {
        var total = DiskUsageTotal()
        for worktree in allLinkedWorktrees { total.add(worktree.diskUsage) }
        return total
    }

    /// Estimated size of worktrees that passed every safety check (eligible or waiting for the delay).
    public var cleanupOpportunity: DiskUsageTotal {
        var total = DiskUsageTotal()
        for worktree in allLinkedWorktrees where worktree.decision.isSafeToRemove {
            total.add(worktree.diskUsage)
        }
        return total
    }

    /// True when something needs the user's attention (errors, account issues, reviews).
    public var needsAttention: Bool {
        if lastScanError != nil { return true }
        return repositories.contains { repository in
            if repository.error != nil { return true }
            switch repository.accountResolution {
            case .needsSelection, .accountUnavailable: return true
            default: break
            }
            return repository.linkedWorktrees.contains { $0.decision.verdict == .needsReview }
        }
    }
}
