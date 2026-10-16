import Foundation

/// UserDefaults-backed preferences. Contains no secrets. Main-actor isolated because the UI reads
/// and writes it; background services receive `AppSettings` snapshots instead.
@MainActor
public final class SettingsStore {
    enum Key {
        static let monitoringInterval = "WC.monitoringIntervalMinutes"
        static let autoCleanupEnabled = "WC.autoCleanupEnabled"
        static let autoCleanupPaused = "WC.autoCleanupPaused"
        static let cleanupConsentAt = "WC.cleanupConsentAt"
        static let cleanupDelay = "WC.cleanupDelayMinutes"
        static let notificationsEnabled = "WC.notificationsEnabled"
        static let launchAtLoginDesired = "WC.launchAtLoginDesired"
        static let appearance = "WC.appearance"
        static let onboardingCompleted = "WC.onboardingCompleted"
    }

    public typealias Observer = @MainActor (AppSettings) -> Void

    private let defaults: UserDefaults
    private var observers: [UUID: Observer] = [:]
    public private(set) var settings: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.load(from: defaults)
    }

    /// Applies a mutation, enforces invariants, persists, and notifies observers if anything changed.
    public func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        if !next.hasCleanupConsent {
            next.autoCleanupEnabled = false
        }
        guard next != settings else { return }
        settings = next
        persist(next)
        for observer in observers.values {
            observer(next)
        }
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        if defaults.object(forKey: Key.monitoringInterval) != nil {
            settings.monitoringInterval = MonitoringInterval(rawValue: defaults.integer(forKey: Key.monitoringInterval)) ?? .default
        }
        if defaults.object(forKey: Key.cleanupDelay) != nil {
            settings.cleanupDelay = CleanupDelay(rawValue: defaults.integer(forKey: Key.cleanupDelay)) ?? .default
        }
        if let consent = defaults.object(forKey: Key.cleanupConsentAt) as? Date {
            settings.cleanupConsentAt = consent
        }
        settings.autoCleanupEnabled = settings.hasCleanupConsent && defaults.bool(forKey: Key.autoCleanupEnabled)
        settings.autoCleanupPaused = defaults.bool(forKey: Key.autoCleanupPaused)
        if defaults.object(forKey: Key.notificationsEnabled) != nil {
            settings.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        }
        if defaults.object(forKey: Key.launchAtLoginDesired) != nil {
            settings.launchAtLoginDesired = defaults.bool(forKey: Key.launchAtLoginDesired)
        }
        if let raw = defaults.string(forKey: Key.appearance) {
            settings.appearance = AppearanceMode(rawValue: raw) ?? .default
        }
        settings.onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        return settings
    }

    private func persist(_ settings: AppSettings) {
        defaults.set(settings.monitoringInterval.rawValue, forKey: Key.monitoringInterval)
        defaults.set(settings.autoCleanupEnabled, forKey: Key.autoCleanupEnabled)
        defaults.set(settings.autoCleanupPaused, forKey: Key.autoCleanupPaused)
        if let consent = settings.cleanupConsentAt {
            defaults.set(consent, forKey: Key.cleanupConsentAt)
        } else {
            defaults.removeObject(forKey: Key.cleanupConsentAt)
        }
        defaults.set(settings.cleanupDelay.rawValue, forKey: Key.cleanupDelay)
        defaults.set(settings.notificationsEnabled, forKey: Key.notificationsEnabled)
        defaults.set(settings.launchAtLoginDesired, forKey: Key.launchAtLoginDesired)
        defaults.set(settings.appearance.rawValue, forKey: Key.appearance)
        defaults.set(settings.onboardingCompleted, forKey: Key.onboardingCompleted)
    }
}
