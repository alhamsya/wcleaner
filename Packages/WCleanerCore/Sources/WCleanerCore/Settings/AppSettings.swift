import Foundation

/// How often repositories are scanned. There is intentionally no "manual only" option;
/// `Check Now` is always available in addition to the interval.
public enum MonitoringInterval: Int, CaseIterable, Codable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    public static let `default`: MonitoringInterval = .fifteenMinutes

    public var minutes: Int { rawValue }
    public var duration: Duration { .seconds(rawValue * 60) }

    public var title: String {
        rawValue == 1 ? "Every minute" : "Every \(rawValue) minutes"
    }
}

/// Delay between a verified merge and automatic cleanup. Zero means "eligible at the next successful scan".
public enum CleanupDelay: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case oneHour = 60
    case sixHours = 360
    case oneDay = 1440

    public static let `default`: CleanupDelay = .none

    public var minutes: Int { rawValue }
    public var timeInterval: TimeInterval { TimeInterval(rawValue * 60) }

    public var title: String {
        switch self {
        case .none: "At the next successful check"
        case .fiveMinutes: "5 minutes after merge is confirmed"
        case .fifteenMinutes: "15 minutes after merge is confirmed"
        case .thirtyMinutes: "30 minutes after merge is confirmed"
        case .oneHour: "1 hour after merge is confirmed"
        case .sixHours: "6 hours after merge is confirmed"
        case .oneDay: "24 hours after merge is confirmed"
        }
    }
}

public enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public static let `default`: AppearanceMode = .system

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Snapshot of all user preferences. Value type so it can cross actor boundaries.
public struct AppSettings: Sendable, Equatable {
    public var monitoringInterval: MonitoringInterval = .default
    /// Off until the user explicitly consents. Can only be true while `cleanupConsentAt` is set.
    public var autoCleanupEnabled: Bool = false
    public var autoCleanupPaused: Bool = false
    /// When the user explicitly consented to WCleaner removing worktrees. Nil means never.
    public var cleanupConsentAt: Date?
    public var cleanupDelay: CleanupDelay = .default
    public var notificationsEnabled: Bool = true
    public var launchAtLoginDesired: Bool = true
    public var appearance: AppearanceMode = .default
    public var onboardingCompleted: Bool = false

    public init() {}

    public var hasCleanupConsent: Bool { cleanupConsentAt != nil }

    /// True only when automatic removal may run right now.
    public var automaticCleanupActive: Bool {
        autoCleanupEnabled && !autoCleanupPaused && hasCleanupConsent
    }
}
