import AppKit
import XCTest
import WCleanerCore
@testable import WCleaner

@MainActor
final class SettingsWindowTests: XCTestCase {
    private var suiteName = ""
    private var model: AppModel!

    override func setUp() async throws {
        suiteName = "io.github.alhamsya.WCleaner.apptests.\(UUID().uuidString)"
        model = AppModel(settingsStore: SettingsStore(defaults: UserDefaults(suiteName: suiteName)!))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        model = nil
    }

    private func makeController() -> SettingsWindowController {
        let coordinator = AppCoordinator(settingsStore: model.settingsStore)
        return SettingsWindowController(model: coordinator.model) { tab in coordinator.makePane(tab) }
    }

    func testTabsAppearInTheRequiredOrder() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["General", "Accounts", "Repositories", "Auto Cleanup", "Notifications", "Appearance", "History", "About"]
        )
    }

    func testToolbarIsAPreferenceStyleIconToolbarAcrossTheTop() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
        XCTAssertEqual(toolbar.items.map(\.label), SettingsTab.allCases.map(\.title))
        XCTAssertTrue(toolbar.items.allSatisfy { $0.image != nil })
        XCTAssertEqual(toolbar.selectedItemIdentifier, SettingsTab.general.toolbarIdentifier)
    }

    func testEveryPaneLoadsAndSelectingUpdatesTitle() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        for tab in SettingsTab.allCases {
            controller.select(tab, animate: false)
            XCTAssertEqual(window.title, tab.title)
            XCTAssertEqual(window.toolbar?.selectedItemIdentifier, tab.toolbarIdentifier)
            XCTAssertGreaterThan(window.contentView?.frame.height ?? 0, 100, "\(tab) has no content")
        }
    }

    func testAppearanceModesMapToNativeAppearances() {
        XCTAssertNil(AppearanceController.appearance(for: .system))
        XCTAssertEqual(AppearanceController.appearance(for: .light)?.name, .aqua)
        XCTAssertEqual(AppearanceController.appearance(for: .dark)?.name, .darkAqua)
    }

    func testAppearanceChangeIsAppliedLiveAndPersisted() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        let coordinator = AppCoordinator(settingsStore: model.settingsStore)
        coordinator.startInterface()
        defer { coordinator.stop() }

        model.settingsStore.update { $0.appearance = .dark }
        XCTAssertEqual(application.appearance?.name, .darkAqua)
        model.settingsStore.update { $0.appearance = .light }
        XCTAssertEqual(application.appearance?.name, .aqua)
        model.settingsStore.update { $0.appearance = .system }
        XCTAssertNil(application.appearance)

        model.settingsStore.update { $0.appearance = .dark }
        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.settings.appearance, .dark)
    }

    func testAppearancePaneRadioButtonsReflectSettings() throws {
        model.settingsStore.update { $0.appearance = .light }
        let pane = AppearancePaneController(model: model)
        _ = pane.view
        let radios = pane.view.descendants(of: NSButton.self).filter { $0.identifier != nil }
        let light = try XCTUnwrap(radios.first { $0.identifier?.rawValue == "light" })
        XCTAssertEqual(light.state, .on)
        XCTAssertEqual(radios.filter { $0.state == .on }.count, 1)
    }

    func testGeneralPaneOffersOnlyTheAllowedIntervals() throws {
        let pane = GeneralPaneController(model: model)
        _ = pane.view
        let popup = try XCTUnwrap(pane.view.descendants(of: NSPopUpButton.self).first)
        XCTAssertEqual(popup.itemTitles, ["Every minute", "Every 5 minutes", "Every 10 minutes", "Every 15 minutes", "Every 30 minutes", "Every 60 minutes"])
        XCTAssertFalse(popup.itemTitles.contains { $0.localizedCaseInsensitiveContains("manual") })
        XCTAssertEqual(popup.titleOfSelectedItem, "Every 15 minutes")
    }
}

extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + subview.descendants(of: type)
        }
    }
}
