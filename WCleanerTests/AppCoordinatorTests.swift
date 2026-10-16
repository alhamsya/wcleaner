import AppKit
import XCTest
import WCleanerCore
@testable import WCleaner

@MainActor
final class AppCoordinatorTests: XCTestCase {
    private var suiteName = ""

    override func setUp() async throws {
        suiteName = "io.github.alhamsya.WCleaner.apptests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testDevelopmentBuildsNeverRemoveUnlessExplicitlyAllowed() {
        guard AppEnvironment.isDebugBuild else { return }
        XCTAssertFalse(AppCoordinator.makeDeletionPolicy(environment: [:]).allowsRealRemoval)
        XCTAssertFalse(AppCoordinator.makeDeletionPolicy(environment: ["WCLEANER_ALLOW_REMOVAL_IN_DEBUG": "yes"]).allowsRealRemoval)
        XCTAssertTrue(AppCoordinator.makeDeletionPolicy(environment: ["WCLEANER_ALLOW_REMOVAL_IN_DEBUG": "1"]).allowsRealRemoval)
    }

    func testMissingOrUnsubstitutedClientIDIsReportedAsNotConfigured() {
        // The test bundle has no WCGitHubClientID key.
        XCTAssertFalse(AppCoordinator.makeConfiguration(bundle: Bundle(for: Self.self)).isConfigured)
        XCTAssertFalse(GitHubConfiguration(clientID: "$(WCLEANER_GITHUB_CLIENT_ID)").isConfigured)
        XCTAssertTrue(AppCoordinator.makeConfiguration(bundle: .main).userAgent.hasPrefix("WCleaner/"))
    }

    func testCreatingTheCoordinatorStartsNothing() {
        let coordinator = AppCoordinator(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!))
        XCTAssertFalse(coordinator.model.servicesReady)
        XCTAssertTrue(coordinator.model.snapshot.repositories.isEmpty)
        XCTAssertTrue(coordinator.model.accounts.isEmpty, "No example account is ever shown as connected")
        XCTAssertFalse(coordinator.model.settings.autoCleanupEnabled)
        XCTAssertNil(coordinator.model.settings.cleanupConsentAt)
    }

    /// Regression: a test host must never start Git, the scheduler or the data folder, so tests can't
    /// scan the developer's real repositories.
    func testStartInsideTestHostStartsNoBackgroundServices() async throws {
        let store = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        store.update { $0.onboardingCompleted = true }
        let coordinator = AppCoordinator(settingsStore: store)
        coordinator.start()
        defer { coordinator.stop() }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(coordinator.model.servicesReady)
        XCTAssertFalse(coordinator.model.gitAvailable)
        XCTAssertEqual(coordinator.model.gitDescription, "Checking for Git…")
    }

    func testMoleScriptForThePreviewIsADryRun() {
        let script = MoleTerminalScript.make(installation: MoleInstallation(path: "/opt/homebrew/bin/mo", version: "1.34.0"), action: .previewClean)
        XCTAssertTrue(script.contains("'/opt/homebrew/bin/mo' 'clean' '--dry-run'"))
    }

    func testUninstallGuideNeverOffersSelfDeletion() {
        let steps = Dialogs.uninstallSteps
        XCTAssertTrue(steps.contains("never deletes itself"))
        XCTAssertTrue(steps.contains("Keychain"))
        XCTAssertTrue(steps.contains("Login Items"))
        XCTAssertFalse(steps.contains("rm -rf"))
    }
}
