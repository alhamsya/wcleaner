import AppKit
import XCTest
@testable import WCleaner

@MainActor
final class StatusIconAnimatorTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 1_000
    }

    // XCTest creates a fresh instance for every test, so these start clean each time.
    private let clock = Clock()
    private var reduceMotion = false
    private var frames: [StatusIcon.Effect] = []

    private func makeAnimator() -> StatusIconAnimator {
        let clock = clock
        let animator = StatusIconAnimator(clock: { clock.now }, reduceMotion: { [unowned self] in reduceMotion }, usesTimer: false)
        animator.onFrame = { [unowned self] in frames.append($0) }
        return animator
    }

    private func advance(_ animator: StatusIconAnimator, to time: TimeInterval) {
        clock.now = 1_000 + time
        animator.update()
    }

    func testIdleIconIsStillAndRunsNoTimer() {
        let animator = makeAnimator()
        animator.update()
        XCTAssertEqual(animator.effect, .none)
        XCTAssertFalse(animator.isAnimating)
        XCTAssertTrue(frames.isEmpty)
    }

    func testBandSweepsWhileCheckingAndFinishesItsPass() throws {
        let animator = makeAnimator()
        animator.setChecking(true)
        XCTAssertTrue(animator.isAnimating)
        XCTAssertEqual(animator.effect, StatusIcon.Effect(dimmed: true, sweep: 0))

        advance(animator, to: StatusIconAnimator.sweepPeriod / 2)
        XCTAssertEqual(try XCTUnwrap(animator.effect.sweep), 0.5, accuracy: 0.001)

        // Checking ends mid-pass: the band completes the pass, then the icon is still again.
        animator.setChecking(false)
        XCTAssertNotNil(animator.effect.sweep)
        advance(animator, to: StatusIconAnimator.sweepPeriod * 0.9)
        XCTAssertNotNil(animator.effect.sweep)
        advance(animator, to: StatusIconAnimator.sweepPeriod)
        XCTAssertEqual(animator.effect, .none)
        XCTAssertFalse(animator.isAnimating)
    }

    func testSweepStopsAfterTheTimeLimitEvenIfCheckingContinues() {
        let animator = makeAnimator()
        animator.setChecking(true)
        advance(animator, to: StatusIconAnimator.sweepLimit + 1)
        XCTAssertEqual(animator.effect, StatusIcon.Effect(dimmed: true), "A long check keeps a still, faded icon")
        XCTAssertFalse(animator.isAnimating)

        animator.setChecking(false)
        XCTAssertEqual(animator.effect, .none)
    }

    func testSparklePlaysOnceAndEnds() throws {
        let animator = makeAnimator()
        animator.playSparkle()
        XCTAssertTrue(animator.isAnimating)
        advance(animator, to: StatusIconAnimator.sparkleDuration / 2)
        XCTAssertEqual(try XCTUnwrap(animator.effect.sparkle), 0.5, accuracy: 0.001)
        advance(animator, to: StatusIconAnimator.sparkleDuration + 0.1)
        XCTAssertNil(animator.effect.sparkle)
        XCTAssertFalse(animator.isAnimating)
    }

    func testReduceMotionShowsOnlyStillFrames() {
        reduceMotion = true
        let animator = makeAnimator()
        animator.setChecking(true)
        XCTAssertEqual(animator.effect, StatusIcon.Effect(dimmed: true))
        XCTAssertFalse(animator.isAnimating)
        animator.playSparkle()
        XCTAssertNil(animator.effect.sparkle)
        XCTAssertFalse(animator.isAnimating)
        animator.setChecking(false)
        XCTAssertEqual(animator.effect, .none)
    }

    func testFramesAreReportedOnlyWhenTheyChange() {
        let animator = makeAnimator()
        animator.setChecking(true)
        reduceMotion = true
        animator.update()
        animator.update()
        XCTAssertEqual(frames, [StatusIcon.Effect(dimmed: true, sweep: 0), StatusIcon.Effect(dimmed: true)])
    }

    func testCheckingIconIsATemplateWithItsOwnDescription() {
        let image = StatusIcon.image(.attention, effect: StatusIcon.Effect(dimmed: true, sweep: 0.3))
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.accessibilityDescription, "WCleaner, checking repositories")
        XCTAssertEqual(StatusIcon.image(.normal, effect: StatusIcon.Effect(sparkle: 0.5)).accessibilityDescription, "WCleaner")
    }
}
