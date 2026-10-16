import XCTest
@testable import WCleanerCore

/// A sleeper whose sleeps only end when the test fires them (or the sleeping task is cancelled).
final class ControlledSleeper: Sleeper, @unchecked Sendable {
    private struct Pending {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var _requested: [Duration] = []

    var requested: [Duration] { lock.withLock { _requested } }
    var pendingDurations: [Duration] { lock.withLock { pending.map(\.duration) } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pending.append(Pending(id: id, duration: duration, continuation: continuation))
                        _requested.append(duration)
                    }
                }
            }
        } onCancel: {
            let cancelled: Pending? = lock.withLock {
                guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
                return pending.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest pending sleep.
    func fire() {
        let next: Pending? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.continuation.resume()
    }
}

/// Records scans; can hold the first scan open to test coalescing.
actor ScanRecorder {
    private(set) var triggers: [ScanTrigger] = []
    private(set) var maximumConcurrent = 0
    private var running = 0
    private var outcomes: [ScanOutcome]
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false

    init(outcomes: [ScanOutcome] = []) {
        self.outcomes = outcomes
    }

    func holdNextScan() { holdNext = true }

    func release() {
        gate?.resume()
        gate = nil
    }

    var isHolding: Bool { gate != nil }

    func scan(_ trigger: ScanTrigger) async -> ScanOutcome {
        triggers.append(trigger)
        running += 1
        maximumConcurrent = max(maximumConcurrent, running)
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        running -= 1
        return outcomes.isEmpty ? .success : outcomes.removeFirst()
    }
}

func waitUntil(
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

final class PollingSchedulerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeScheduler(
        interval: MonitoringInterval,
        sleeper: ControlledSleeper,
        recorder: ScanRecorder
    ) async -> PollingScheduler {
        let now = fixedNow
        let scheduler = PollingScheduler(interval: interval, sleeper: sleeper, wakeDelay: .seconds(30), now: { now })
        await scheduler.setHandler { trigger in await recorder.scan(trigger) }
        return scheduler
    }

    func testStartupScanThenRegularInterval() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder()
        let scheduler = await makeScheduler(interval: .fiveMinutes, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))

        await waitUntil { sleeper.pendingDurations == [.seconds(3)] }
        let beforeFirstSleep = await recorder.triggers
        XCTAssertTrue(beforeFirstSleep.isEmpty)
        sleeper.fire()
        await waitUntil { sleeper.pendingDurations == [.seconds(300)] }
        sleeper.fire()
        await waitUntil { sleeper.requested.count == 3 }

        let triggers = await recorder.triggers
        XCTAssertEqual(triggers, [.startup, .scheduled])
        XCTAssertEqual(sleeper.requested, [.seconds(3), .seconds(300), .seconds(300)])
        let next = await scheduler.nextScanAt
        XCTAssertEqual(next, fixedNow.addingTimeInterval(300))
        await scheduler.stop()
    }

    func testCheckNowDuringScanIsCoalescedAndNeverOverlaps() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder()
        let scheduler = await makeScheduler(interval: .fifteenMinutes, sleeper: sleeper, recorder: recorder)
        await recorder.holdNextScan()
        await scheduler.start(initialDelay: .seconds(3))
        await waitUntil { sleeper.pendingDurations.count == 1 }
        sleeper.fire()
        await waitUntil { await recorder.isHolding }

        await scheduler.checkNow()
        await scheduler.checkNow()
        await scheduler.checkNow()
        await recorder.release()

        await waitUntil { await recorder.triggers.count == 2 && sleeper.pendingDurations.count == 1 }
        let triggers = await recorder.triggers
        XCTAssertEqual(triggers, [.startup, .manual])
        let maximumConcurrent = await recorder.maximumConcurrent
        XCTAssertEqual(maximumConcurrent, 1)
        await scheduler.stop()
    }

    func testCheckNowRestartsTheInterval() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder()
        let scheduler = await makeScheduler(interval: .tenMinutes, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))
        await waitUntil { sleeper.pendingDurations == [.seconds(3)] }

        await scheduler.checkNow()
        await waitUntil { sleeper.pendingDurations == [.seconds(600)] }
        let triggers = await recorder.triggers
        XCTAssertEqual(triggers, [.manual])
        await scheduler.stop()
        await waitUntil { sleeper.pendingDurations.isEmpty }
    }

    func testNetworkFailuresBackOffExponentially() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder(outcomes: [.networkFailure, .networkFailure, .networkFailure, .success])
        let scheduler = await makeScheduler(interval: .oneMinute, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))
        for expectedCount in 2...5 {
            await waitUntil { sleeper.requested.count == expectedCount - 1 && sleeper.pendingDurations.count == 1 }
            sleeper.fire()
        }
        await waitUntil { sleeper.requested.count == 5 }
        XCTAssertEqual(sleeper.requested, [.seconds(3), .seconds(60), .seconds(120), .seconds(240), .seconds(60)])
        await scheduler.stop()
    }

    func testRateLimitWaitsForTheResetTime() async {
        let sleeper = ControlledSleeper()
        let reset = fixedNow.addingTimeInterval(600)
        let recorder = ScanRecorder(outcomes: [.rateLimited(until: reset)])
        let scheduler = await makeScheduler(interval: .oneMinute, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))
        await waitUntil { sleeper.pendingDurations.count == 1 }
        sleeper.fire()
        await waitUntil { sleeper.requested.count == 2 }
        XCTAssertEqual(sleeper.requested.last, .seconds(630))
        await scheduler.stop()
    }

    func testSleepSuspendsAndWakeRunsExactlyOneDelayedScan() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder()
        let scheduler = await makeScheduler(interval: .fifteenMinutes, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))
        await waitUntil { sleeper.pendingDurations.count == 1 }

        await scheduler.systemWillSleep()
        await waitUntil { sleeper.pendingDurations.isEmpty }
        let nextWhileAsleep = await scheduler.nextScanAt
        XCTAssertNil(nextWhileAsleep)
        await scheduler.checkNow()
        let scansWhileAsleep = await recorder.triggers
        XCTAssertTrue(scansWhileAsleep.isEmpty)

        await scheduler.systemDidWake()
        await scheduler.systemDidWake()
        await waitUntil { sleeper.pendingDurations == [.seconds(30)] }
        sleeper.fire()
        await waitUntil { sleeper.pendingDurations == [.seconds(900)] }
        let triggers = await recorder.triggers
        XCTAssertEqual(triggers, [.wake])
        await scheduler.stop()
    }

    func testIntervalChangeReschedules() async {
        let sleeper = ControlledSleeper()
        let recorder = ScanRecorder()
        let scheduler = await makeScheduler(interval: .fifteenMinutes, sleeper: sleeper, recorder: recorder)
        await scheduler.start(initialDelay: .seconds(3))
        await waitUntil { sleeper.pendingDurations.count == 1 }
        sleeper.fire()
        await waitUntil { sleeper.pendingDurations == [.seconds(900)] }

        await scheduler.updateInterval(.fiveMinutes)
        await waitUntil { sleeper.pendingDurations == [.seconds(300)] }
        let interval = await scheduler.currentInterval
        XCTAssertEqual(interval, .fiveMinutes)
        await scheduler.stop()
    }
}

final class BackoffPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSuccessUsesTheInterval() {
        for interval in MonitoringInterval.allCases {
            XCTAssertEqual(BackoffPolicy.nextDelay(interval: interval, outcome: .success, consecutiveFailures: 0, now: now), interval.duration)
            XCTAssertEqual(BackoffPolicy.nextDelay(interval: interval, outcome: .partialFailure, consecutiveFailures: 0, now: now), interval.duration)
        }
    }

    func testBackoffIsCappedAndNeverShorterThanTheInterval() {
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .networkFailure, consecutiveFailures: 1, now: now), .seconds(60))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .networkFailure, consecutiveFailures: 4, now: now), .seconds(480))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .networkFailure, consecutiveFailures: 50, now: now), .seconds(3600))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .sixtyMinutes, outcome: .networkFailure, consecutiveFailures: 1, now: now), .seconds(3600))
    }

    func testRateLimitUsesResetTimeWithinBounds() {
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .rateLimited(until: now.addingTimeInterval(100)), consecutiveFailures: 1, now: now), .seconds(130))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .rateLimited(until: now.addingTimeInterval(86_400)), consecutiveFailures: 1, now: now), .seconds(7200))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .oneMinute, outcome: .rateLimited(until: nil), consecutiveFailures: 1, now: now), .seconds(900))
        XCTAssertEqual(BackoffPolicy.nextDelay(interval: .sixtyMinutes, outcome: .rateLimited(until: now), consecutiveFailures: 1, now: now), .seconds(3600))
    }
}
