import AppKit
import WCleanerCore

@MainActor
final class AboutPaneController: SettingsPaneViewController {
    override func buildContent() {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        icon.setAccessibilityLabel("WCleaner app icon")

        let name = UIFactory.label("WCleaner", font: .systemFont(ofSize: 20, weight: .semibold))
        var versionText = "Version \(AppEnvironment.appVersion) (\(AppEnvironment.buildNumber))"
        if AppEnvironment.isDebugBuild { versionText += " · Development build" }
        let version = UIFactory.note(versionText)
        let tagline = UIFactory.wrapping("A lightweight menu bar app that finds Git worktrees, matches them to GitHub pull requests, and carefully removes worktrees whose pull requests are verifiably merged.")
        let header = UIFactory.hStack([icon, UIFactory.vStack([name, version], spacing: 2)], spacing: 14)
        stack.addArrangedSubview(header)
        addFullWidth(tagline)

        addSection("Project")
        let repoButton = UIFactory.button("View on GitHub", target: self, action: #selector(openRepository))
        let licenseButton = UIFactory.button("MIT License", target: self, action: #selector(openLicense))
        stack.addArrangedSubview(UIFactory.hStack([repoButton, licenseButton]))
        addFullWidth(UIFactory.note(
            "WCleaner is open source under the MIT License. It uses only Apple system frameworks. "
                + "Mole integration is optional: Mole is a separate GPL-3.0 project by tw93 and is never bundled."
        ))

        addSection("Uninstall")
        addFullWidth(UIFactory.note("WCleaner never deletes itself or your files. The uninstall guide explains how to turn off Launch at Login, remove its Keychain items and settings, and move the app to the Trash."))
        stack.addArrangedSubview(UIFactory.button("Uninstall Guide…", target: self, action: #selector(showUninstall)))
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool { false }

    @objc private func openRepository() {
        NSWorkspace.shared.open(AppEnvironment.repositoryURL)
    }

    @objc private func openLicense() {
        NSWorkspace.shared.open(AppEnvironment.repositoryURL.appendingPathComponent("blob/HEAD/LICENSE"))
    }

    @objc private func showUninstall() { model.actions?.showUninstallInstructions() }
}
