import XCTest
@testable import WCleanerCore

final class WorktreeTrackingStoreTests: XCTestCase {
    private var directory: URL!
    private let repositoryID = UUID()
    private let head = EligibilityFixture.head
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-tracking-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> WorktreeTrackingStore {
        WorktreeTrackingStore(directory: AppDataDirectory(url: directory))
    }

    private var key: WorktreeKey { WorktreeKey(repositoryID: repositoryID, path: "/tmp/wt/feature") }

    private func evidence(state: PullRequestState = .merged, head: String? = nil, number: Int = 12) -> PullRequestEvidence {
        var evidence = EligibilityFixture().evidence
        evidence.state = state
        evidence.mergedAt = state == .merged ? start : nil
        evidence.headSHA = head ?? self.head
        evidence.number = number
        return evidence
    }

    func testFirstConfirmationIsKeptAcrossScansAndRestarts() async {
        let store = makeStore()
        let first = await store.observe(key, match: .matched(evidence()), localHead: head, now: start)
        XCTAssertEqual(first.mergeConfirmedAt, start)
        let later = await store.observe(key, match: .matched(evidence()), localHead: head, now: start.addingTimeInterval(600))
        XCTAssertEqual(later.mergeConfirmedAt, start)

        let reloaded = await makeStore().tracking(for: key)
        XCTAssertNotNil(reloaded?.mergeConfirmedAt)
        XCTAssertEqual(reloaded?.mergeConfirmedAt?.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded?.confirmedPullRequest, 12)
    }

    func testLookupFailureKeepsButContraryEvidenceClearsConfirmation() async {
        let store = makeStore()
        await store.observe(key, match: .matched(evidence()), localHead: head, now: start)
        let afterFailure = await store.observe(key, match: .unavailable("offline"), localHead: head, now: start.addingTimeInterval(60))
        XCTAssertEqual(afterFailure.mergeConfirmedAt, start)

        let reopened = await store.observe(key, match: .matched(evidence(state: .open)), localHead: head, now: start.addingTimeInterval(120))
        XCTAssertNil(reopened.mergeConfirmedAt)

        let merged = await store.observe(key, match: .matched(evidence()), localHead: head, now: start.addingTimeInterval(180))
        XCTAssertEqual(merged.mergeConfirmedAt, start.addingTimeInterval(180), "The delay restarts from the new confirmation")
    }

    func testNewLocalCommitOrDifferentPullRequestRestartsTheDelay() async {
        let store = makeStore()
        await store.observe(key, match: .matched(evidence()), localHead: head, now: start)
        let moved = await store.observe(key, match: .matched(evidence()), localHead: EligibilityFixture.otherHead, now: start.addingTimeInterval(60))
        XCTAssertNil(moved.mergeConfirmedAt)

        await store.observe(key, match: .matched(evidence()), localHead: head, now: start.addingTimeInterval(120))
        let otherPR = await store.observe(key, match: .matched(evidence(number: 99)), localHead: head, now: start.addingTimeInterval(180))
        XCTAssertEqual(otherPR.confirmedPullRequest, 99)
        XCTAssertEqual(otherPR.mergeConfirmedAt, start.addingTimeInterval(180))

        let notFound = await store.observe(key, match: .notFound, localHead: head, now: start.addingTimeInterval(240))
        XCTAssertNil(notFound.mergeConfirmedAt)
    }

    /// The cleanup delay is a grace period after the worktree became removable, not after the merge.
    func testDecideConfirmsTheMergeOnlyWhileEveryOtherCheckPasses() async {
        let store = makeStore()
        var fixture = EligibilityFixture()
        let key = WorktreeKey(repositoryID: fixture.repository.id, path: fixture.record.path)
        fixture.settings.delay = .oneHour
        fixture.inspection.status?.untrackedCount = 1
        fixture.now = start

        let blocked = await store.decide(fixture.input, key: key)
        XCTAssertEqual(blocked.decision.verdict, .blocked)
        XCTAssertNil(blocked.tracking.mergeConfirmedAt)

        fixture.inspection.status?.untrackedCount = 0
        fixture.now = start.addingTimeInterval(600)
        let clean = await store.decide(fixture.input, key: key)
        XCTAssertEqual(clean.tracking.mergeConfirmedAt, fixture.now)
        XCTAssertEqual(clean.decision.verdict, .waiting(until: fixture.now.addingTimeInterval(3600)))

        fixture.inspection.status?.untrackedCount = 1
        fixture.now = start.addingTimeInterval(1200)
        let blockedAgain = await store.decide(fixture.input, key: key)
        XCTAssertNil(blockedAgain.tracking.mergeConfirmedAt, "New local content restarts the grace period")
    }

    func testApprovalBindsToPullRequestAndHead() async {
        let store = makeStore()
        await store.approve(key, pullRequest: 12, head: head, now: start)
        let tracking = await makeStore().tracking(for: key)
        XCTAssertEqual(tracking?.approves(pullRequest: 12, head: head), true)
        XCTAssertEqual(tracking?.approves(pullRequest: 12, head: EligibilityFixture.otherHead), false)
        XCTAssertEqual(tracking?.approves(pullRequest: 13, head: head), false)
    }

    func testInvalidationAndPruning() async {
        let store = makeStore()
        let otherKey = WorktreeKey(repositoryID: repositoryID, path: "/tmp/wt/other")
        await store.observe(key, match: .matched(evidence()), localHead: head, now: start)
        await store.observe(otherKey, match: .matched(evidence()), localHead: head, now: start)

        await store.invalidateConfirmations(repositoryID: repositoryID)
        let invalidated = await store.tracking(for: key)
        XCTAssertNil(invalidated?.mergeConfirmedAt)

        await store.prune(repositoryID: repositoryID, keeping: [key.path])
        let pruned = await store.tracking(for: otherKey)
        XCTAssertNil(pruned)
        let kept = await store.tracking(for: key)
        XCTAssertNotNil(kept)

        await store.removeRepository(repositoryID)
        let removed = await makeStore().tracking(for: key)
        XCTAssertNil(removed)
    }
}
