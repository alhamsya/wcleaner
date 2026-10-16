import Foundation

public enum ScanTrigger: Sendable, Equatable {
    case startup
    case scheduled
    case manual
    case wake
}

public enum ScanOutcome: Sendable, Equatable {
    case success
    /// Some lookups failed transiently; the rest succeeded.
    case partialFailure
    /// Every remote lookup failed (offline, DNS, server errors).
    case networkFailure
    case rateLimited(until: Date?)
    /// Not run (another scan in progress, or suspended for system sleep).
    case skipped
}

/// Pure delay policy: the regular interval normally, exponential backoff on failures,
/// and the server's reset time on rate limits. Never shorter than the user's interval.
public enum BackoffPolicy {
    public static let maximumBackoff: Duration = .seconds(60 * 60)
    public static let maximumRateLimitWait: Duration = .seconds(2 * 60 * 60)

    public static func nextDelay(
        interval: MonitoringInterval,
        outcome: ScanOutcome,
        consecutiveFailures: Int,
        now: Date
    ) -> Duration {
        let base = interval.duration
        switch outcome {
        case .success, .partialFailure, .skipped:
            return base
        case .networkFailure:
            let exponent = min(max(consecutiveFailures - 1, 0), 10)
            let backoff = min(Duration.seconds(60) * (1 << exponent), maximumBackoff)
            return max(base, backoff)
        case .rateLimited(let until):
            guard let until else {
                return max(base, .seconds(15 * 60))
            }
            let wait = Duration.seconds(Int(max(0, until.timeIntervalSince(now)).rounded(.up)) + 30)
            return max(base, min(wait, maximumRateLimitWait))
        }
    }
}

/// One shared timer loop for all repositories and accounts. Scans never overlap; `Check Now` during a
/// scan is coalesced into a single follow-up scan. On system sleep the loop stops; on wake it restarts
/// with one delayed scan, so there is never a burst of catch-up scans.
public actor PollingScheduler {
    public typealias Handler = @Sendable (ScanTrigger) async -> ScanOutcome

    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date
    private let wakeDelay: Duration
    private var interval: MonitoringInterval
    private var handler: Handler?
    private var nextScanObserver: (@Sendable (Date?) -> Void)?
    private var loop: Task<Void, Never>?
    private var isScanning = false
    private var pendingManual = false
    private var suspended = false
    private(set) var consecutiveFailures = 0
    public private(set) var nextScanAt: Date?

    public init(
        interval: MonitoringInterval = .default,
        sleeper: any Sleeper = TaskSleeper(),
        wakeDelay: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.interval = interval
        self.sleeper = sleeper
        self.wakeDelay = wakeDelay
        self.now = now
    }

    public func setHandler(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func setNextScanObserver(_ observer: @escaping @Sendable (Date?) -> Void) {
        nextScanObserver = observer
    }

    public var currentInterval: MonitoringInterval { interval }
    public var scanning: Bool { isScanning }

    public func start(initialDelay: Duration = .seconds(3)) {
        suspended = false
        startLoop(after: initialDelay, firstTrigger: .startup)
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        setNextScan(nil)
    }

    public func updateInterval(_ newInterval: MonitoringInterval) {
        guard newInterval != interval else { return }
        interval = newInterval
        guard loop != nil, !suspended else { return }
        startLoop(after: newInterval.duration, firstTrigger: .scheduled)
    }

    /// Runs a scan now (or right after the current one) and restarts the regular interval afterwards.
    public func checkNow() async {
        guard !suspended else { return }
        if isScanning {
            pendingManual = true
            return
        }
        let outcome = await performScan(.manual)
        if outcome != .skipped, loop != nil {
            startLoop(after: delay(after: outcome), firstTrigger: .scheduled)
        }
    }

    public func systemWillSleep() {
        suspended = true
        pendingManual = false
        loop?.cancel()
        loop = nil
        setNextScan(nil)
    }

    public func systemDidWake() {
        guard suspended else { return }
        suspended = false
        startLoop(after: min(wakeDelay, interval.duration), firstTrigger: .wake)
    }

    // MARK: Loop

    private func startLoop(after delay: Duration, firstTrigger: ScanTrigger) {
        loop?.cancel()
        setNextScan(now().addingTimeInterval(delay.timeInterval))
        loop = Task { [weak self] in
            await self?.runLoop(firstDelay: delay, firstTrigger: firstTrigger)
        }
    }

    private func runLoop(firstDelay: Duration, firstTrigger: ScanTrigger) async {
        var delay = firstDelay
        var trigger = firstTrigger
        while !Task.isCancelled {
            do {
                try await sleeper.sleep(for: delay)
            } catch {
                return
            }
            if Task.isCancelled || suspended { return }
            let outcome = await performScan(trigger)
            if Task.isCancelled { return }
            delay = self.delay(after: outcome)
            trigger = .scheduled
            setNextScan(now().addingTimeInterval(delay.timeInterval))
        }
    }

    private func performScan(_ trigger: ScanTrigger) async -> ScanOutcome {
        guard let handler, !suspended else { return .skipped }
        if isScanning {
            if trigger == .manual { pendingManual = true }
            return .skipped
        }
        isScanning = true
        var outcome = await handler(trigger)
        record(outcome)
        while pendingManual && !suspended {
            pendingManual = false
            outcome = await handler(.manual)
            record(outcome)
        }
        isScanning = false
        return outcome
    }

    private func record(_ outcome: ScanOutcome) {
        switch outcome {
        case .success, .partialFailure:
            consecutiveFailures = 0
        case .networkFailure, .rateLimited:
            consecutiveFailures += 1
        case .skipped:
            break
        }
    }

    private func delay(after outcome: ScanOutcome) -> Duration {
        BackoffPolicy.nextDelay(interval: interval, outcome: outcome, consecutiveFailures: consecutiveFailures, now: now())
    }

    private func setNextScan(_ date: Date?) {
        nextScanAt = date
        nextScanObserver?(date)
    }
}
