import Foundation

/// Injectable sleeping so schedules and polling loops can be tested deterministically.
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Real sleeping with timer tolerance so macOS can coalesce wake-ups (lower energy use).
public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        let seconds = duration.timeInterval
        let tolerance = Duration.milliseconds(Int(min(60, max(0.1, seconds * 0.1)) * 1000))
        try await Task.sleep(for: duration, tolerance: tolerance, clock: .continuous)
    }
}
