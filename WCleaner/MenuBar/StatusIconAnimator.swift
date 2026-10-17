import AppKit
import QuartzCore

/// Drives the menu bar icon's short animations: a band sweeps across the badge while WCleaner checks
/// repositories (for at most `sweepLimit`), and a sparkle plays once after a worktree was cleaned up.
/// A 30 fps timer runs only while something moves, so an idle WCleaner keeps no timer at all.
/// With Reduce Motion the icon only fades while checking and the sparkle is skipped.
@MainActor
final class StatusIconAnimator {
    static let framesPerSecond: Double = 30
    static let sweepPeriod: TimeInterval = 1.4
    static let sweepLimit: TimeInterval = 30
    static let sparkleDuration: TimeInterval = 1.2

    var onFrame: ((StatusIcon.Effect) -> Void)?
    private(set) var effect: StatusIcon.Effect = .none
    /// True while frames are being produced (the timer runs, or would run when `usesTimer` is false).
    private(set) var isAnimating = false

    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private let usesTimer: Bool
    private var timer: Timer?
    private var isChecking = false
    private var sweepStartedAt: TimeInterval?
    /// When checking ends, the band finishes its current pass before the icon settles.
    private var sweepEndsAt: TimeInterval?
    private var sparkleStartedAt: TimeInterval?

    init(
        clock: @escaping () -> TimeInterval = CACurrentMediaTime,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        usesTimer: Bool = true
    ) {
        self.clock = clock
        self.reduceMotion = reduceMotion
        self.usesTimer = usesTimer
    }

    func setChecking(_ checking: Bool) {
        guard checking != isChecking else { return }
        isChecking = checking
        let now = clock()
        if checking {
            sweepEndsAt = nil
            if sweepStartedAt == nil { sweepStartedAt = now }
        } else if let start = sweepStartedAt {
            let elapsed = now - start
            if reduceMotion() || elapsed >= Self.sweepLimit {
                sweepStartedAt = nil
            } else {
                let passes = max(1, (elapsed / Self.sweepPeriod).rounded(.up))
                sweepEndsAt = start + passes * Self.sweepPeriod
            }
        }
        update()
    }

    func playSparkle() {
        guard !reduceMotion() else { return }
        sparkleStartedAt = clock()
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isAnimating = false
    }

    /// Computes the current frame, reports it when it changed, and starts or stops the timer.
    func update() {
        let now = clock()
        let motion = !reduceMotion()
        var next = StatusIcon.Effect()

        if let start = sweepStartedAt {
            let elapsed = now - start
            let passFinished = sweepEndsAt.map { now >= $0 } ?? false
            if !isChecking && (passFinished || !motion || elapsed >= Self.sweepLimit) {
                sweepStartedAt = nil
                sweepEndsAt = nil
            } else if motion && elapsed < Self.sweepLimit {
                next.dimmed = true
                next.sweep = CGFloat((elapsed / Self.sweepPeriod).truncatingRemainder(dividingBy: 1))
            }
        }
        if isChecking { next.dimmed = true }

        if let start = sparkleStartedAt {
            let progress = (now - start) / Self.sparkleDuration
            if motion && progress < 1 {
                next.sparkle = CGFloat(max(progress, 0))
            } else {
                sparkleStartedAt = nil
            }
        }

        if next != effect {
            effect = next
            onFrame?(next)
        }
        let moving = next.sweep != nil || next.sparkle != nil
        if moving && !isAnimating {
            isAnimating = true
            if usesTimer { startTimer() }
        } else if !moving && isAnimating {
            stop()
        }
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 0.005
        // `.common` keeps the animation running while the status menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
