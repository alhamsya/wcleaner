import AppKit
import WCleanerCore

@MainActor
final class AppearancePaneController: SettingsPaneViewController {
    private var buttons: [AppearanceMode: NSButton] = [:]

    override func buildContent() {
        addSection("Appearance")
        var radios: [NSView] = []
        for mode in AppearanceMode.allCases {
            let button = UIFactory.radio(mode.title, target: self, action: #selector(modeChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            buttons[mode] = button
            radios.append(button)
        }
        stack.addArrangedSubview(UIFactory.vStack(radios, spacing: 6))
        addFullWidth(UIFactory.note("System follows your Mac's Light or Dark appearance. Changes apply immediately and are remembered."))
    }

    override func refresh() {
        let current = model.settings.appearance
        for (mode, button) in buttons {
            button.state = mode == current ? .on : .off
        }
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool { change == .settings }

    @objc private func modeChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = AppearanceMode(rawValue: raw) else { return }
        model.settingsStore.update { $0.appearance = mode }
    }
}
