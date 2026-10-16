import XCTest
@testable import WCleanerCore

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "io.github.alhamsya.WCleaner.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let settings = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(settings.monitoringInterval, .fifteenMinutes)
        XCTAssertFalse(settings.autoCleanupEnabled)
        XCTAssertNil(settings.cleanupConsentAt)
        XCTAssertEqual(settings.cleanupDelay, .none)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertTrue(settings.launchAtLoginDesired)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.automaticCleanupActive)
    }

    func testIntervalsNeverIncludeManualOnly() {
        XCTAssertEqual(MonitoringInterval.allCases.map(\.minutes), [1, 5, 10, 15, 30, 60])
        XCTAssertEqual(CleanupDelay.allCases.map(\.minutes), [0, 5, 15, 30, 60, 360, 1440])
    }

    func testPersistsAcrossInstances() {
        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.monitoringInterval = .fiveMinutes
            $0.appearance = .dark
            $0.cleanupDelay = .sixHours
            $0.notificationsEnabled = false
        }
        let reloaded = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(reloaded.monitoringInterval, .fiveMinutes)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.cleanupDelay, .sixHours)
        XCTAssertFalse(reloaded.notificationsEnabled)
    }

    func testAutoCleanupRequiresConsent() {
        let store = SettingsStore(defaults: defaults)
        store.update { $0.autoCleanupEnabled = true }
        XCTAssertFalse(store.settings.autoCleanupEnabled)

        store.update {
            $0.cleanupConsentAt = Date()
            $0.autoCleanupEnabled = true
        }
        XCTAssertTrue(store.settings.automaticCleanupActive)

        store.update { $0.autoCleanupPaused = true }
        XCTAssertFalse(store.settings.automaticCleanupActive)

        store.update { $0.cleanupConsentAt = nil }
        XCTAssertFalse(store.settings.autoCleanupEnabled)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set(7, forKey: SettingsStore.Key.monitoringInterval)
        defaults.set(0, forKey: "WC.manualOnly")
        defaults.set(999, forKey: SettingsStore.Key.cleanupDelay)
        defaults.set("neon", forKey: SettingsStore.Key.appearance)
        defaults.set(true, forKey: SettingsStore.Key.autoCleanupEnabled)
        let settings = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(settings.monitoringInterval, .fifteenMinutes)
        XCTAssertEqual(settings.cleanupDelay, .none)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.autoCleanupEnabled, "Auto cleanup without stored consent must load as off")
    }

    func testObserversAreNotifiedOnlyOnChange() {
        let store = SettingsStore(defaults: defaults)
        var count = 0
        store.observe { _ in count += 1 }
        store.update { $0.appearance = .light }
        store.update { $0.appearance = .light }
        XCTAssertEqual(count, 1)
    }
}
