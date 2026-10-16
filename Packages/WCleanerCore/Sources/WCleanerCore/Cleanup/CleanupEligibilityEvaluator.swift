import Foundation

/// The subset of settings that affects cleanup policy.
public struct CleanupPolicySettings: Sendable, Equatable {
    public var cleanupConsentAt: Date?
    public var autoCleanupEnabled: Bool
    public var autoCleanupPaused: Bool
    public var delay: CleanupDelay

    public init(cleanupConsentAt: Date?, autoCleanupEnabled: Bool, autoCleanupPaused: Bool, delay: CleanupDelay) {
        self.cleanupConsentAt = cleanupConsentAt
        self.autoCleanupEnabled = autoCleanupEnabled
        self.autoCleanupPaused = autoCleanupPaused
        self.delay = delay
    }

    public init(_ settings: AppSettings) {
        self.init(
            cleanupConsentAt: settings.cleanupConsentAt,
            autoCleanupEnabled: settings.autoCleanupEnabled,
            autoCleanupPaused: settings.autoCleanupPaused,
            delay: settings.cleanupDelay
        )
    }
}

/// Everything the evaluator needs to judge one worktree. Assembled fresh for every decision.
public struct EligibilityInput: Sendable {
    public var repository: RegisteredRepository
    public var record: WorktreeRecord
    public var isPrimary: Bool
    /// Paths of every worktree Git lists for the repository (including this one).
    public var allWorktreePaths: [String]
    public var commonDirectory: String
    public var inspection: LocalWorktreeInspection?
    public var githubRepository: ResolvedGitHubRepository?
    public var account: AccountResolution
    public var pullRequest: PullRequestMatch?
    public var tracking: WorktreeTracking?
    public var settings: CleanupPolicySettings
    public var now: Date
    /// Set immediately before removal: requires the deep (gitlink) inspection to have run.
    public var requireDeepInspection: Bool

    public init(
        repository: RegisteredRepository,
        record: WorktreeRecord,
        isPrimary: Bool,
        allWorktreePaths: [String],
        commonDirectory: String,
        inspection: LocalWorktreeInspection?,
        githubRepository: ResolvedGitHubRepository?,
        account: AccountResolution,
        pullRequest: PullRequestMatch?,
        tracking: WorktreeTracking?,
        settings: CleanupPolicySettings,
        now: Date,
        requireDeepInspection: Bool = false
    ) {
        self.repository = repository
        self.record = record
        self.isPrimary = isPrimary
        self.allWorktreePaths = allWorktreePaths
        self.commonDirectory = commonDirectory
        self.inspection = inspection
        self.githubRepository = githubRepository
        self.account = account
        self.pullRequest = pullRequest
        self.tracking = tracking
        self.settings = settings
        self.now = now
        self.requireDeepInspection = requireDeepInspection
    }
}

public struct CleanupDecision: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// Every safety check passed and the delay has elapsed.
        case eligible
        /// Every safety check passed; automatic cleanup waits until the delay elapses.
        case waiting(until: Date)
        /// Safe except that the user must review this worktree first.
        case needsReview
        /// At least one safety check failed.
        case blocked
    }

    public var verdict: Verdict
    /// Blocking and review reasons first, then informational ones.
    public var reasons: [EligibilityReason]
    /// The merged pull request the decision is based on, when there is one.
    public var evidence: PullRequestEvidence?
    /// True only when automatic cleanup may remove this worktree now.
    public var automaticCleanupAllowed: Bool

    public init(verdict: Verdict, reasons: [EligibilityReason], evidence: PullRequestEvidence?, automaticCleanupAllowed: Bool) {
        self.verdict = verdict
        self.reasons = reasons
        self.evidence = evidence
        self.automaticCleanupAllowed = automaticCleanupAllowed
    }

    /// True when the local and remote safety checks passed (the user may remove it manually).
    public var isSafeToRemove: Bool {
        switch verdict {
        case .eligible, .waiting: true
        case .needsReview, .blocked: false
        }
    }

    public var blockingReasons: [EligibilityReason] { reasons.filter { $0.kind == .blocking } }

    public var title: String {
        switch verdict {
        case .eligible: automaticCleanupAllowed ? "Will be cleaned up" : "Safe to remove"
        case .waiting: "Waiting for cleanup delay"
        case .needsReview: "Needs review"
        case .blocked: "Kept"
        }
    }

    public var summary: String {
        switch verdict {
        case .eligible:
            let pr = evidence.map { "PR #\($0.number) merged" } ?? "Merged"
            return "\(pr); no local changes."
        case .waiting(let until):
            return "Merged; eligible after \(EnglishDateFormat.dateTime.format(until))."
        case .needsReview, .blocked:
            return reasons.first(where: { $0.kind != .info })?.message ?? "Not eligible."
        }
    }
}

/// Pure, deterministic cleanup policy. Fails closed: anything unknown or ambiguous blocks removal.
public struct CleanupEligibilityEvaluator: Sendable {
    /// Merges this close after enrollment or consent still need a review, in case the Mac's clock was behind.
    public static let enrollmentClockMargin: TimeInterval = 15 * 60

    public init() {}

    public func evaluate(_ input: EligibilityInput) -> CleanupDecision {
        var blocking: [EligibilityReason] = []
        var review: [EligibilityReason] = []
        var info: [EligibilityReason] = []

        evaluateStructure(input, into: &blocking)
        evaluateLocalState(input, into: &blocking)
        let evidence = evaluateHosting(input, into: &blocking)

        if let evidence, evidence.state == .merged, let mergedAt = evidence.mergedAt {
            let baseline = max(input.repository.addedAt, input.settings.cleanupConsentAt ?? input.repository.addedAt)
            // `mergedAt` comes from GitHub's clock, the baseline from this Mac's: allow for clock skew.
            if mergedAt < baseline.addingTimeInterval(Self.enrollmentClockMargin),
               !(input.tracking?.approves(pullRequest: evidence.number, head: evidence.headSHA) ?? false) {
                review.append(.mergedBeforeEnrollment(mergedAt))
            }
        }

        if !blocking.isEmpty {
            return CleanupDecision(verdict: .blocked, reasons: blocking + review, evidence: evidence, automaticCleanupAllowed: false)
        }
        if !review.isEmpty {
            return CleanupDecision(verdict: .needsReview, reasons: review, evidence: evidence, automaticCleanupAllowed: false)
        }
        guard let evidence else {
            // Unreachable when no blocking reasons exist, but never default to eligible.
            return CleanupDecision(verdict: .blocked, reasons: [.noPullRequest], evidence: nil, automaticCleanupAllowed: false)
        }

        let confirmedAt: Date
        if let tracking = input.tracking, tracking.confirms(evidence), let stored = tracking.mergeConfirmedAt {
            confirmedAt = stored
        } else {
            confirmedAt = input.now
        }
        let eligibleAt = confirmedAt.addingTimeInterval(input.settings.delay.timeInterval)
        let verdict: CleanupDecision.Verdict = input.now < eligibleAt ? .waiting(until: eligibleAt) : .eligible

        if case .waiting(let until) = verdict {
            info.append(.waitingForDelay(until: until))
        }
        if input.settings.cleanupConsentAt == nil {
            info.append(.cleanupConsentMissing)
        } else if !input.settings.autoCleanupEnabled {
            info.append(.automaticCleanupOff)
        } else if input.settings.autoCleanupPaused {
            info.append(.automaticCleanupPaused)
        }

        let automatic = verdict == .eligible
            && input.settings.cleanupConsentAt != nil
            && input.settings.autoCleanupEnabled
            && !input.settings.autoCleanupPaused
        return CleanupDecision(verdict: verdict, reasons: info, evidence: evidence, automaticCleanupAllowed: automatic)
    }

    private func evaluateStructure(_ input: EligibilityInput, into blocking: inout [EligibilityReason]) {
        let record = input.record
        if input.isPrimary { blocking.append(.primaryWorktree) }
        if record.isBare { blocking.append(.bareRepository) }
        if record.isLocked { blocking.append(.locked(record.lockReason)) }
        if record.isPrunable { blocking.append(.prunable(record.prunableReason)) }
        if record.isDetached || record.branchName == nil { blocking.append(.detachedHead) }
        if !record.unknownAttributes.isEmpty { blocking.append(.unknownWorktreeAttributes(record.unknownAttributes)) }

        let ownPath = PathCanonicalizer.standardize(record.path)
        for other in input.allWorktreePaths {
            let otherPath = PathCanonicalizer.standardize(other)
            if otherPath != ownPath && PathCanonicalizer.isPath(otherPath, inside: ownPath) {
                blocking.append(.containsOtherWorktree(other))
            }
        }
        if PathCanonicalizer.isPath(input.commonDirectory, inside: ownPath)
            || PathCanonicalizer.isPath(input.repository.path, inside: ownPath)
            || PathCanonicalizer.isPath(input.repository.commonDirectory, inside: ownPath) {
            blocking.append(.containsRepositoryData)
        }
    }

    private func evaluateLocalState(_ input: EligibilityInput, into blocking: inout [EligibilityReason]) {
        guard let inspection = input.inspection else {
            blocking.append(.statusUnavailable("The worktree has not been inspected."))
            return
        }
        guard inspection.path == input.record.path else {
            blocking.append(.expectationChanged("The inspection refers to a different path."))
            return
        }
        guard inspection.exists else {
            blocking.append(.missingDirectory)
            return
        }
        guard inspection.isDirectory else {
            blocking.append(.notADirectory)
            return
        }
        if inspection.isSymlinkAmbiguous { blocking.append(.symlinkAmbiguous) }
        switch inspection.gitFileStatus {
        case .valid: break
        case .missing: blocking.append(.notALinkedWorktree("Its .git file is missing."))
        case .isDirectory: blocking.append(.notALinkedWorktree("It contains its own .git directory (an independent repository)."))
        case .mismatch(let detail): blocking.append(.notALinkedWorktree(detail))
        }
        if inspection.hasGitmodulesFile || inspection.hasSubmoduleGitDirectories || inspection.hasGitlinks == true {
            blocking.append(.submodules)
        }
        if let hidden = inspection.hiddenIndexEntryCount, hidden > 0 {
            blocking.append(.hiddenIndexEntries(hidden))
        }
        if let refs = inspection.perWorktreeRefs, !refs.isEmpty {
            blocking.append(.perWorktreeRefs(refs))
        }
        if let nested = inspection.nestedGitEntries, !nested.isEmpty {
            blocking.append(.nestedGitEntries(nested))
        }
        if input.requireDeepInspection {
            if inspection.hasGitlinks == nil || inspection.hiddenIndexEntryCount == nil {
                blocking.append(.statusUnavailable(inspection.gitlinkCheckError ?? "The index check did not run."))
            }
            if inspection.perWorktreeRefs == nil {
                blocking.append(.statusUnavailable(inspection.perWorktreeRefsError ?? "The per-worktree ref check did not run."))
            }
            if inspection.nestedGitEntries == nil {
                blocking.append(.statusUnavailable(inspection.nestedGitScanError ?? "The check for nested .git folders did not run."))
            }
        }
        if !inspection.operationsInProgress.isEmpty {
            blocking.append(.operationInProgress(inspection.operationsInProgress.joined(separator: ", ")))
        }

        if let status = inspection.status {
            if status.stagedCount > 0 { blocking.append(.stagedChanges(status.stagedCount)) }
            if status.unstagedCount > 0 { blocking.append(.unstagedChanges(status.unstagedCount)) }
            if status.unmergedCount > 0 { blocking.append(.unmergedChanges(status.unmergedCount)) }
            if status.untrackedCount > 0 { blocking.append(.untrackedFiles(status.untrackedCount)) }
            if status.ignoredCount > 0 { blocking.append(.ignoredFiles(status.ignoredCount)) }
            if status.submoduleChangeCount > 0 { blocking.append(.submoduleChanges(status.submoduleChangeCount)) }
        } else {
            blocking.append(.statusUnavailable(inspection.statusError ?? "Git status did not complete."))
        }

        if let head = inspection.headSHA {
            if head != input.record.head { blocking.append(.headChangedDuringCheck) }
        } else {
            blocking.append(.headUnavailable(inspection.headError ?? "Unknown error."))
        }
    }

    /// Returns the pull request evidence only when it is fully consistent with the repository and account.
    private func evaluateHosting(_ input: EligibilityInput, into blocking: inout [EligibilityReason]) -> PullRequestEvidence? {
        let assignedAccount: AccountID?
        switch input.account {
        case .assigned(let account, _): assignedAccount = account
        case .needsSelection: assignedAccount = nil; blocking.append(.needsAccountSelection)
        case .needsAccount: assignedAccount = nil; blocking.append(.needsAccount)
        case .accountUnavailable(_, let reason): assignedAccount = nil; blocking.append(.accountUnavailable(reason))
        case .notGitHub(let detail): assignedAccount = nil; blocking.append(.notGitHubRepository(detail))
        case .unverified(let detail): assignedAccount = nil; blocking.append(.accountUnverified(detail))
        }

        guard let githubRepository = input.githubRepository else {
            if assignedAccount != nil {
                blocking.append(.accountUnverified("The GitHub repository identity is not verified."))
            }
            return nil
        }

        switch input.pullRequest {
        case .none:
            blocking.append(.pullRequestLookupFailed("Pull requests have not been checked yet."))
            return nil
        case .notFound:
            blocking.append(.noPullRequest)
            return nil
        case .unavailable(let detail):
            blocking.append(.pullRequestLookupFailed(detail))
            return nil
        case .ambiguous(let numbers):
            blocking.append(.ambiguousPullRequest(numbers))
            return nil
        case .headMismatch(let evidence, let localHead):
            blocking.append(.headDiffersFromPullRequest(local: localHead, pullRequest: evidence.headSHA))
            return nil
        case .matched(let evidence):
            if evidence.baseRepositoryID != githubRepository.id {
                blocking.append(.repositoryIdentityMismatch("The pull request belongs to a different repository."))
            }
            if let assignedAccount, evidence.accountID != assignedAccount {
                blocking.append(.repositoryIdentityMismatch("The pull request was checked with a different account."))
            }
            guard let localHead = input.record.head, evidence.headSHA == localHead else {
                blocking.append(.headDiffersFromPullRequest(local: input.record.head ?? "unknown", pullRequest: evidence.headSHA))
                return nil
            }
            if !evidence.headRepositoryVerified { blocking.append(.headRepositoryUnverified) }
            switch evidence.state {
            case .merged:
                if evidence.mergedAt == nil { blocking.append(.pullRequestStateUnknown(evidence.number)) }
            case .open:
                blocking.append(.pullRequestOpen(evidence.number))
            case .closedUnmerged:
                blocking.append(.pullRequestClosedUnmerged(evidence.number))
            case .unknown:
                blocking.append(.pullRequestStateUnknown(evidence.number))
            }
            return evidence
        }
    }
}
