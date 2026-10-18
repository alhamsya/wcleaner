import XCTest
@testable import WCleanerCore

/// Builds a fully-safe baseline input; each test breaks exactly one thing.
struct EligibilityFixture {
    static let head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let otherHead = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let account = AccountID(host: "github.com", userID: 42)
    static let otherAccount = AccountID(host: "github.com", userID: 7)
    static let enrolledAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let now = enrolledAt.addingTimeInterval(86_400 * 10)
    static let mergedAt = enrolledAt.addingTimeInterval(86_400 * 5)

    var repository = RegisteredRepository(
        displayName: "repo",
        path: "/Users/me/code/repo",
        commonDirectory: "/Users/me/code/repo/.git",
        addedAt: enrolledAt
    )
    var record = WorktreeRecord(path: "/Users/me/code/wt/feature", head: head, branchRef: "refs/heads/feature")
    var isPrimary = false
    var otherPaths = ["/Users/me/code/repo"]
    var inspection = LocalWorktreeInspection(
        path: "/Users/me/code/wt/feature",
        worktreeGitDirectory: "/Users/me/code/repo/.git/worktrees/feature",
        status: GitStatusSummary(branchHead: "feature"),
        headSHA: head,
        hasGitlinks: false,
        checkedOutSubmodules: []
    )
    var inspectionPresent = true
    var githubRepository: ResolvedGitHubRepository? = ResolvedGitHubRepository(id: 1001, owner: "octo", name: "repo", htmlURL: "https://github.com/octo/repo")
    var account: AccountResolution = .assigned(account, automatic: true)
    var evidence = PullRequestEvidence(
        number: 12,
        title: "Add feature",
        url: "https://github.com/octo/repo/pull/12",
        state: .merged,
        mergedAt: mergedAt,
        headSHA: head,
        headRef: "feature",
        headRepositoryID: 1001,
        headRepositoryFullName: "octo/repo",
        baseRepositoryID: 1001,
        baseRef: "main",
        accountID: account,
        fetchedAt: now,
        headRepositoryVerified: true
    )
    var pullRequestOverride: PullRequestMatch??
    var tracking: WorktreeTracking?
    var settings = CleanupPolicySettings(cleanupConsentAt: enrolledAt, autoCleanupEnabled: true, autoCleanupPaused: false, delay: .none)
    var now = now
    var requireDeep = false

    var input: EligibilityInput {
        EligibilityInput(
            repository: repository,
            record: record,
            isPrimary: isPrimary,
            allWorktreePaths: otherPaths + [record.path],
            commonDirectory: repository.commonDirectory,
            inspection: inspectionPresent ? inspection : nil,
            githubRepository: githubRepository,
            account: account,
            pullRequest: pullRequestOverride ?? .matched(evidence),
            tracking: tracking,
            settings: settings,
            now: now,
            requireDeepInspection: requireDeep
        )
    }

    func decide() -> CleanupDecision {
        CleanupEligibilityEvaluator().evaluate(input)
    }
}

final class CleanupEligibilityEvaluatorTests: XCTestCase {
    private func assertBlocked(
        _ fixture: EligibilityFixture,
        containing reason: EligibilityReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let decision = fixture.decide()
        XCTAssertEqual(decision.verdict, .blocked, file: file, line: line)
        XCTAssertFalse(decision.automaticCleanupAllowed, file: file, line: line)
        XCTAssertFalse(decision.isSafeToRemove, file: file, line: line)
        XCTAssertTrue(decision.reasons.contains(reason), "Missing \(reason) in \(decision.reasons)", file: file, line: line)
    }

    func testBaselineIsEligibleForAutomaticCleanup() {
        let decision = EligibilityFixture().decide()
        XCTAssertEqual(decision.verdict, .eligible)
        XCTAssertTrue(decision.automaticCleanupAllowed)
        XCTAssertTrue(decision.isSafeToRemove)
        XCTAssertEqual(decision.evidence?.number, 12)
    }

    // MARK: Structure

    func testPrimaryWorktreeIsNeverEligible() {
        var fixture = EligibilityFixture()
        fixture.isPrimary = true
        assertBlocked(fixture, containing: .primaryWorktree)
    }

    func testBareLockedPrunableDetachedAndUnknownAttributes() {
        var bare = EligibilityFixture(); bare.record.isBare = true
        assertBlocked(bare, containing: .bareRepository)

        var locked = EligibilityFixture(); locked.record.isLocked = true; locked.record.lockReason = "on USB drive"
        assertBlocked(locked, containing: .locked("on USB drive"))

        var prunable = EligibilityFixture(); prunable.record.isPrunable = true
        assertBlocked(prunable, containing: .prunable(nil))

        var detached = EligibilityFixture(); detached.record.isDetached = true; detached.record.branchRef = nil
        assertBlocked(detached, containing: .detachedHead)

        var unknown = EligibilityFixture(); unknown.record.unknownAttributes = ["future"]
        assertBlocked(unknown, containing: .unknownWorktreeAttributes(["future"]))
    }

    func testNestedWorktreeAndRepositoryDataBlock() {
        var nested = EligibilityFixture()
        nested.otherPaths.append("/Users/me/code/wt/feature/inner")
        assertBlocked(nested, containing: .containsOtherWorktree("/Users/me/code/wt/feature/inner"))

        var containsRepo = EligibilityFixture()
        containsRepo.record.path = "/Users/me/code"
        containsRepo.inspection.path = "/Users/me/code"
        assertBlocked(containsRepo, containing: .containsRepositoryData)
    }

    func testSiblingWithSharedPrefixIsNotTreatedAsNested() {
        var fixture = EligibilityFixture()
        fixture.otherPaths.append("/Users/me/code/wt/feature-two")
        XCTAssertEqual(fixture.decide().verdict, .eligible)
    }

    func testMissingSymlinkAndForeignGitDirectory() {
        var missing = EligibilityFixture(); missing.inspection.exists = false
        assertBlocked(missing, containing: .missingDirectory)

        var symlink = EligibilityFixture(); symlink.inspection.isSymlinkAmbiguous = true
        assertBlocked(symlink, containing: .symlinkAmbiguous)

        var independent = EligibilityFixture(); independent.inspection.gitFileStatus = .isDirectory
        XCTAssertEqual(independent.decide().verdict, .blocked)

        var mismatch = EligibilityFixture(); mismatch.inspection.gitFileStatus = .mismatch("elsewhere")
        assertBlocked(mismatch, containing: .notALinkedWorktree("elsewhere"))
    }

    func testSubmoduleRepositoriesAndCheckedOutSubmodulesBlock() {
        var modulesDirectory = EligibilityFixture(); modulesDirectory.inspection.hasSubmoduleGitDirectories = true
        assertBlocked(modulesDirectory, containing: .submodules)

        var checkedOut = EligibilityFixture()
        checkedOut.inspection.hasGitmodulesFile = true
        checkedOut.inspection.hasGitlinks = true
        checkedOut.inspection.checkedOutSubmodules = ["vendor/lib"]
        assertBlocked(checkedOut, containing: .checkedOutSubmodules(["vendor/lib"]))
    }

    /// A submodule that was never checked out is an empty folder: removing the worktree loses nothing.
    func testSubmodulesThatWereNeverCheckedOutDoNotBlock() {
        var fixture = EligibilityFixture()
        fixture.requireDeep = true
        fixture.inspection.hasGitmodulesFile = true
        fixture.inspection.hasGitlinks = true
        fixture.inspection.checkedOutSubmodules = []
        fixture.inspection.hiddenIndexEntryCount = 0
        fixture.inspection.perWorktreeRefs = []
        fixture.inspection.nestedGitEntries = []
        XCTAssertEqual(fixture.decide().verdict, .eligible)
    }

    func testDeepInspectionRequiredBeforeRemoval() {
        var fixture = EligibilityFixture()
        fixture.requireDeep = true
        fixture.inspection.hasGitlinks = nil
        XCTAssertEqual(fixture.decide().verdict, .blocked)
    }

    /// Changes hidden by skip-worktree or assume-unchanged flags, and refs that live only in this
    /// worktree, would be lost with it.
    func testHiddenIndexEntriesAndPerWorktreeRefsBlock() {
        var hidden = EligibilityFixture(); hidden.inspection.hiddenIndexEntryCount = 2
        assertBlocked(hidden, containing: .hiddenIndexEntries(2))

        var refs = EligibilityFixture(); refs.inspection.perWorktreeRefs = ["refs/bisect/bad"]
        assertBlocked(refs, containing: .perWorktreeRefs(["refs/bisect/bad"]))

        var nested = EligibilityFixture(); nested.inspection.nestedGitEntries = ["docs/.git"]
        assertBlocked(nested, containing: .nestedGitEntries(["docs/.git"]))
    }

    func testEveryDeepCheckMustHaveRunBeforeRemoval() {
        var complete = EligibilityFixture()
        complete.requireDeep = true
        complete.inspection.hiddenIndexEntryCount = 0
        complete.inspection.perWorktreeRefs = []
        complete.inspection.nestedGitEntries = []
        XCTAssertEqual(complete.decide().verdict, .eligible)

        var noIndexScan = complete; noIndexScan.inspection.hiddenIndexEntryCount = nil
        XCTAssertEqual(noIndexScan.decide().verdict, .blocked)
        var noRefs = complete; noRefs.inspection.perWorktreeRefs = nil
        XCTAssertEqual(noRefs.decide().verdict, .blocked)
        var noGitlinks = complete; noGitlinks.inspection.hasGitlinks = nil
        XCTAssertEqual(noGitlinks.decide().verdict, .blocked)
        var noSubmoduleCheck = complete; noSubmoduleCheck.inspection.checkedOutSubmodules = nil
        XCTAssertEqual(noSubmoduleCheck.decide().verdict, .blocked)
        var noNestedScan = complete; noNestedScan.inspection.nestedGitEntries = nil
        XCTAssertEqual(noNestedScan.decide().verdict, .blocked)
    }

    // MARK: Local content

    func testEveryKindOfLocalContentBlocks() {
        let cases: [(WritableKeyPath<GitStatusSummary, Int>, EligibilityReason)] = [
            (\.stagedCount, .stagedChanges(1)),
            (\.unstagedCount, .unstagedChanges(1)),
            (\.unmergedCount, .unmergedChanges(1)),
            (\.untrackedCount, .untrackedFiles(1)),
            (\.ignoredCount, .ignoredFiles(1)),
            (\.submoduleChangeCount, .submoduleChanges(1)),
        ]
        for (keyPath, reason) in cases {
            var fixture = EligibilityFixture()
            fixture.inspection.status?[keyPath: keyPath] = 1
            assertBlocked(fixture, containing: reason)
        }
    }

    // MARK: Local checks alone (removal without a merged pull request)

    func testLocalChecksAreReportedSeparatelyFromPullRequestReasons() {
        var open = EligibilityFixture(); open.evidence.state = .open; open.evidence.mergedAt = nil
        let openDecision = open.decide()
        XCTAssertEqual(openDecision.verdict, .blocked)
        XCTAssertTrue(openDecision.localChecksPassed, "An open pull request is not a local reason")
        XCTAssertEqual(openDecision.localBlockingReasons, [])

        var noPR = EligibilityFixture(); noPR.pullRequestOverride = .some(.notFound)
        XCTAssertTrue(noPR.decide().localChecksPassed)

        var noAccount = EligibilityFixture(); noAccount.account = .needsAccount; noAccount.pullRequestOverride = .some(nil)
        XCTAssertTrue(noAccount.decide().localChecksPassed)

        var dirty = EligibilityFixture(); dirty.evidence.state = .open; dirty.inspection.status?.untrackedCount = 1
        XCTAssertFalse(dirty.decide().localChecksPassed)
        XCTAssertEqual(dirty.decide().localBlockingReasons, [.untrackedFiles(1)])

        var primary = EligibilityFixture(); primary.isPrimary = true
        XCTAssertFalse(primary.decide().localChecksPassed)
        var detached = EligibilityFixture(); detached.record = WorktreeRecord(path: detached.record.path, head: EligibilityFixture.head, isDetached: true)
        XCTAssertFalse(detached.decide().localChecksPassed)
        var notInspected = EligibilityFixture(); notInspected.inspectionPresent = false
        XCTAssertFalse(notInspected.decide().localChecksPassed)
    }

    func testOnlyStagedUnstagedAndUntrackedChangesCanBeStashed() {
        func decision(_ local: [EligibilityReason]?) -> CleanupDecision {
            CleanupDecision(verdict: .blocked, reasons: local ?? [], evidence: nil, automaticCleanupAllowed: false, localBlockingReasons: local)
        }
        XCTAssertTrue(decision([.stagedChanges(1), .unstagedChanges(7), .untrackedFiles(2)]).changesCanBeStashed)
        XCTAssertFalse(decision([]).changesCanBeStashed, "Nothing to save")
        XCTAssertFalse(decision(nil).changesCanBeStashed, "Unknown")
        for other: EligibilityReason in [.ignoredFiles(1), .unmergedChanges(1), .submoduleChanges(1), .hiddenIndexEntries(1),
                                         .primaryWorktree, .detachedHead, .operationInProgress("merge"), .statusUnavailable("x")] {
            XCTAssertFalse(decision([.unstagedChanges(1), other]).changesCanBeStashed, "\(other)")
        }

        var dirty = EligibilityFixture(); dirty.evidence.state = .open
        dirty.inspection.status?.unstagedCount = 7
        XCTAssertTrue(dirty.decide().changesCanBeStashed)
        dirty.inspection.status?.ignoredCount = 1
        XCTAssertFalse(dirty.decide().changesCanBeStashed)
    }

    func testDecisionWithoutLocalResultsNeverCountsAsPassed() {
        XCTAssertFalse(CleanupDecision(verdict: .blocked, reasons: [], evidence: nil, automaticCleanupAllowed: false).localChecksPassed)
    }

    // MARK: Disposable ignored files

    func testIgnoredFilesBlockUnlessEveryOneIsMarkedDisposable() {
        var fixture = EligibilityFixture()
        fixture.inspection.status?.ignoredCount = 2
        fixture.inspection.status?.ignoredPaths = [".code-review-graph/", ".env"]
        assertBlocked(fixture, containing: .ignoredFiles(2, paths: [".code-review-graph/", ".env"]))

        fixture.repository.disposableIgnoredPaths = [".code-review-graph"]
        assertBlocked(fixture, containing: .ignoredFiles(1, paths: [".env"]))

        fixture.repository.disposableIgnoredPaths = [".code-review-graph", ".env"]
        let decision = fixture.decide()
        XCTAssertEqual(decision.verdict, .eligible)
        XCTAssertTrue(decision.automaticCleanupAllowed)
        XCTAssertEqual(decision.reasons, [.disposableIgnoredFiles([".code-review-graph/", ".env"])])
        XCTAssertEqual(decision.summary, "PR #12 merged; no local changes except ignored files marked disposable.")
    }

    func testDisposablePathCoversOnlyItselfAndItsContents() {
        var fixture = EligibilityFixture()
        fixture.repository.disposableIgnoredPaths = ["build"]
        fixture.inspection.status?.ignoredCount = 3
        fixture.inspection.status?.ignoredPaths = ["build/", "app/build/", "build.log"]
        assertBlocked(fixture, containing: .ignoredFiles(2, paths: ["app/build/", "build.log"]))
    }

    /// Entries Git reported beyond the list limit, or a count without paths, cannot be checked.
    func testIgnoredFilesThatWereNotListedBlock() {
        var truncated = EligibilityFixture()
        truncated.repository.disposableIgnoredPaths = ["node_modules"]
        truncated.inspection.status?.ignoredCount = 3
        truncated.inspection.status?.ignoredPaths = ["node_modules/"]
        truncated.inspection.status?.ignoredPathsComplete = false
        assertBlocked(truncated, containing: .ignoredFiles(2, paths: []))

        var countOnly = EligibilityFixture()
        countOnly.repository.disposableIgnoredPaths = ["node_modules"]
        countOnly.inspection.status?.ignoredCount = 1
        assertBlocked(countOnly, containing: .ignoredFiles(1))
    }

    func testUnknownStatusFailsClosed() {
        var fixture = EligibilityFixture()
        fixture.inspection.status = nil
        fixture.inspection.statusError = "timed out"
        assertBlocked(fixture, containing: .statusUnavailable("timed out"))

        var notInspected = EligibilityFixture()
        notInspected.inspectionPresent = false
        XCTAssertEqual(notInspected.decide().verdict, .blocked)
    }

    func testOperationInProgressAndHeadChanges() {
        var rebase = EligibilityFixture(); rebase.inspection.operationsInProgress = ["rebase"]
        assertBlocked(rebase, containing: .operationInProgress("rebase"))

        var moved = EligibilityFixture(); moved.inspection.headSHA = EligibilityFixture.otherHead
        assertBlocked(moved, containing: .headChangedDuringCheck)

        var unreadable = EligibilityFixture(); unreadable.inspection.headSHA = nil; unreadable.inspection.headError = "boom"
        assertBlocked(unreadable, containing: .headUnavailable("boom"))
    }

    // MARK: Accounts and repository identity

    func testAccountStatesBlock() {
        var selection = EligibilityFixture(); selection.account = .needsSelection([EligibilityFixture.account, EligibilityFixture.otherAccount])
        assertBlocked(selection, containing: .needsAccountSelection)

        var none = EligibilityFixture(); none.account = .needsAccount
        assertBlocked(none, containing: .needsAccount)

        var unavailable = EligibilityFixture(); unavailable.account = .accountUnavailable(EligibilityFixture.account, reason: "expired")
        assertBlocked(unavailable, containing: .accountUnavailable("expired"))

        var unverified = EligibilityFixture(); unverified.account = .unverified("rate limited")
        assertBlocked(unverified, containing: .accountUnverified("rate limited"))

        var notGitHub = EligibilityFixture(); notGitHub.account = .notGitHub("no remote")
        assertBlocked(notGitHub, containing: .notGitHubRepository("no remote"))
    }

    func testEvidenceFromAnotherAccountOrRepositoryBlocks() {
        var otherAccount = EligibilityFixture()
        otherAccount.evidence.accountID = EligibilityFixture.otherAccount
        XCTAssertEqual(otherAccount.decide().verdict, .blocked)

        var otherRepository = EligibilityFixture()
        otherRepository.evidence.baseRepositoryID = 9999
        XCTAssertEqual(otherRepository.decide().verdict, .blocked)

        var unresolved = EligibilityFixture()
        unresolved.githubRepository = nil
        XCTAssertEqual(unresolved.decide().verdict, .blocked)
    }

    // MARK: Pull requests

    func testPullRequestStatesBlockUnlessVerifiedMerged() {
        var open = EligibilityFixture(); open.evidence.state = .open; open.evidence.mergedAt = nil
        assertBlocked(open, containing: .pullRequestOpen(12))

        var closed = EligibilityFixture(); closed.evidence.state = .closedUnmerged; closed.evidence.mergedAt = nil
        assertBlocked(closed, containing: .pullRequestClosedUnmerged(12))

        var unknown = EligibilityFixture(); unknown.evidence.state = .unknown
        assertBlocked(unknown, containing: .pullRequestStateUnknown(12))

        var mergedWithoutTimestamp = EligibilityFixture(); mergedWithoutTimestamp.evidence.mergedAt = nil
        assertBlocked(mergedWithoutTimestamp, containing: .pullRequestStateUnknown(12))
    }

    func testClosedUnmergedIsNeverTreatedAsMerged() {
        XCTAssertEqual(PullRequestState.from(apiState: "closed", mergedAt: nil), .closedUnmerged)
        XCTAssertEqual(PullRequestState.from(apiState: "closed", mergedAt: Date()), .merged)
        XCTAssertEqual(PullRequestState.from(apiState: "open", mergedAt: Date()), .open)
        XCTAssertEqual(PullRequestState.from(apiState: "weird", mergedAt: Date()), .unknown)
    }

    func testMissingAmbiguousFailedOrMismatchedPullRequestsBlock() {
        var none = EligibilityFixture(); none.pullRequestOverride = .some(.notFound)
        assertBlocked(none, containing: .noPullRequest)

        var unchecked = EligibilityFixture(); unchecked.pullRequestOverride = .some(nil)
        XCTAssertEqual(unchecked.decide().verdict, .blocked)

        var failed = EligibilityFixture(); failed.pullRequestOverride = .some(.unavailable("HTTP 403"))
        assertBlocked(failed, containing: .pullRequestLookupFailed("HTTP 403"))

        var ambiguous = EligibilityFixture(); ambiguous.pullRequestOverride = .some(.ambiguous([3, 4]))
        assertBlocked(ambiguous, containing: .ambiguousPullRequest([3, 4]))

        let fixture = EligibilityFixture()
        var mismatch = EligibilityFixture()
        mismatch.pullRequestOverride = .some(.headMismatch(fixture.evidence, localHead: EligibilityFixture.otherHead))
        XCTAssertEqual(mismatch.decide().verdict, .blocked)
    }

    func testLocalHeadMustEqualPullRequestHead() {
        var fixture = EligibilityFixture()
        fixture.evidence.headSHA = EligibilityFixture.otherHead
        assertBlocked(fixture, containing: .headDiffersFromPullRequest(local: EligibilityFixture.head, pullRequest: EligibilityFixture.otherHead))
    }

    func testUnverifiedHeadRepositoryBlocks() {
        var fixture = EligibilityFixture()
        fixture.evidence.headRepositoryVerified = false
        assertBlocked(fixture, containing: .headRepositoryUnverified)
    }

    // MARK: Enrollment and review

    func testMergedBeforeEnrollmentNeedsReview() {
        var fixture = EligibilityFixture()
        fixture.evidence.mergedAt = EligibilityFixture.enrolledAt.addingTimeInterval(-60)
        let decision = fixture.decide()
        XCTAssertEqual(decision.verdict, .needsReview)
        XCTAssertFalse(decision.automaticCleanupAllowed)
        XCTAssertFalse(decision.isSafeToRemove)
    }

    func testMergedBeforeConsentNeedsReview() {
        var fixture = EligibilityFixture()
        fixture.settings.cleanupConsentAt = EligibilityFixture.mergedAt.addingTimeInterval(60)
        XCTAssertEqual(fixture.decide().verdict, .needsReview)
    }

    /// GitHub's merge time and this Mac's enrollment time come from different clocks.
    func testMergeJustAfterEnrollmentStillNeedsReviewWithinTheClockMargin() {
        let margin = CleanupEligibilityEvaluator.enrollmentClockMargin
        var close = EligibilityFixture()
        close.evidence.mergedAt = EligibilityFixture.enrolledAt.addingTimeInterval(margin - 60)
        XCTAssertEqual(close.decide().verdict, .needsReview)

        var clear = EligibilityFixture()
        clear.evidence.mergedAt = EligibilityFixture.enrolledAt.addingTimeInterval(margin + 60)
        XCTAssertEqual(clear.decide().verdict, .eligible)
    }

    func testReviewApprovalAppliesOnlyToTheReviewedState() {
        var fixture = EligibilityFixture()
        fixture.evidence.mergedAt = EligibilityFixture.enrolledAt.addingTimeInterval(-60)
        fixture.tracking = WorktreeTracking(
            firstSeenAt: EligibilityFixture.enrolledAt,
            reviewApproval: ReviewApproval(approvedAt: EligibilityFixture.now, pullRequestNumber: 12, headSHA: EligibilityFixture.head)
        )
        XCTAssertEqual(fixture.decide().verdict, .eligible)

        fixture.tracking?.reviewApproval?.headSHA = EligibilityFixture.otherHead
        XCTAssertEqual(fixture.decide().verdict, .needsReview)

        fixture.tracking?.reviewApproval = ReviewApproval(approvedAt: EligibilityFixture.now, pullRequestNumber: 99, headSHA: EligibilityFixture.head)
        XCTAssertEqual(fixture.decide().verdict, .needsReview)
    }

    func testReviewNeverOverridesBlockingReasons() {
        var fixture = EligibilityFixture()
        fixture.evidence.mergedAt = EligibilityFixture.enrolledAt.addingTimeInterval(-60)
        fixture.tracking = WorktreeTracking(
            firstSeenAt: EligibilityFixture.enrolledAt,
            reviewApproval: ReviewApproval(approvedAt: EligibilityFixture.now, pullRequestNumber: 12, headSHA: EligibilityFixture.head)
        )
        fixture.inspection.status?.ignoredCount = 1
        XCTAssertEqual(fixture.decide().verdict, .blocked)
    }

    // MARK: Delay and automation settings

    func testZeroDelayIsEligibleAtFirstConfirmation() {
        let decision = EligibilityFixture().decide()
        XCTAssertEqual(decision.verdict, .eligible)
    }

    func testDelayWaitsFromFirstConfirmation() {
        var fixture = EligibilityFixture()
        fixture.settings.delay = .oneHour
        let decision = fixture.decide()
        XCTAssertEqual(decision.verdict, .waiting(until: EligibilityFixture.now.addingTimeInterval(3600)))
        XCTAssertFalse(decision.automaticCleanupAllowed)
        XCTAssertTrue(decision.isSafeToRemove)

        fixture.tracking = WorktreeTracking(
            firstSeenAt: EligibilityFixture.enrolledAt,
            mergeConfirmedAt: EligibilityFixture.now.addingTimeInterval(-3601),
            confirmedPullRequest: 12,
            confirmedHead: EligibilityFixture.head,
            confirmedAccount: EligibilityFixture.account
        )
        XCTAssertEqual(fixture.decide().verdict, .eligible)
    }

    func testConfirmationForDifferentEvidenceRestartsDelay() {
        var fixture = EligibilityFixture()
        fixture.settings.delay = .oneHour
        fixture.tracking = WorktreeTracking(
            firstSeenAt: EligibilityFixture.enrolledAt,
            mergeConfirmedAt: EligibilityFixture.now.addingTimeInterval(-7200),
            confirmedPullRequest: 12,
            confirmedHead: EligibilityFixture.head,
            confirmedAccount: EligibilityFixture.otherAccount
        )
        XCTAssertEqual(fixture.decide().verdict, .waiting(until: EligibilityFixture.now.addingTimeInterval(3600)))
    }

    func testAutomationSettingsOnlyAffectAutomaticFlag() {
        var off = EligibilityFixture(); off.settings.autoCleanupEnabled = false
        var decision = off.decide()
        XCTAssertEqual(decision.verdict, .eligible)
        XCTAssertFalse(decision.automaticCleanupAllowed)
        XCTAssertTrue(decision.reasons.contains(.automaticCleanupOff))

        var paused = EligibilityFixture(); paused.settings.autoCleanupPaused = true
        decision = paused.decide()
        XCTAssertFalse(decision.automaticCleanupAllowed)
        XCTAssertTrue(decision.reasons.contains(.automaticCleanupPaused))

        var noConsent = EligibilityFixture(); noConsent.settings.cleanupConsentAt = nil
        decision = noConsent.decide()
        XCTAssertFalse(decision.automaticCleanupAllowed)
        XCTAssertTrue(decision.reasons.contains(.cleanupConsentMissing))
    }

    func testEveryBlockingReasonHasAMessage() {
        let reasons: [EligibilityReason] = [
            .primaryWorktree, .bareRepository, .locked(nil), .prunable("x"), .detachedHead, .missingDirectory,
            .ignoredFiles(2), .needsAccount, .noPullRequest, .ambiguousPullRequest([1, 2]),
            .mergedBeforeEnrollment(Date()), .deletionDisabledInDevelopmentBuild,
        ]
        for reason in reasons {
            XCTAssertFalse(reason.message.isEmpty)
        }
        XCTAssertEqual(EligibilityReason.ignoredFiles(2).kind, .blocking)
        XCTAssertEqual(EligibilityReason.checkedOutSubmodules(["a"]).kind, .blocking)
        XCTAssertEqual(EligibilityReason.disposableIgnoredFiles(["a"]).kind, .info)
        XCTAssertEqual(
            EligibilityReason.ignoredFiles(7, paths: ["a", "b", "c", "d", "e", "f"]).message,
            "7 ignored files or folders would be lost: a, b, c, d, e and 2 more."
        )
        XCTAssertEqual(EligibilityReason.mergedBeforeEnrollment(Date()).kind, .review)
        XCTAssertEqual(EligibilityReason.automaticCleanupOff.kind, .info)
    }
}
