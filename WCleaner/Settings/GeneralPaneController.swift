import AppKit
import WCleanerCore

@MainActor
final class GeneralPaneController: SettingsPaneViewController {
    private var intervalPopup: NSPopUpButton!
    private let lastCheckLabel = UIFactory.label("")
    private var launchCheckbox: NSButton!
    private let launchStatusLabel = UIFactory.note("")
    private var loginItemsButton: NSButton!
    private let gitLabel = UIFactory.note("")
    private let moleStatusLabel = UIFactory.note("")
    private var moleOpenButton: NSButton!
    private var molePreviewButton: NSButton!
    private var moleRunButton: NSButton!

    override func buildContent() {
        addSection("Monitoring")
        intervalPopup = UIFactory.popup(MonitoringInterval.allCases.map(\.title), target: self, action: #selector(intervalChanged))
        intervalPopup.setAccessibilityLabel("Check interval")
        let checkNow = UIFactory.button("Check Now", target: self, action: #selector(checkNow))
        stack.addArrangedSubview(UIFactory.form([
            ("Check pull requests", intervalPopup),
            ("Last check", UIFactory.hStack([lastCheckLabel, checkNow])),
        ]))
        addFullWidth(UIFactory.note(
            "WCleaner checks your repositories on this schedule even when automatic cleanup is off, "
                + "so the menu always shows current pull request status. Checks are skipped while your Mac sleeps "
                + "and are never repeated to catch up after waking."
        ))

        addSection("Startup")
        launchCheckbox = UIFactory.checkbox("Launch WCleaner at login", target: self, action: #selector(launchAtLoginChanged))
        loginItemsButton = UIFactory.button("Open Login Items Settings…", target: self, action: #selector(openLoginItems))
        stack.addArrangedSubview(launchCheckbox)
        addFullWidth(launchStatusLabel)
        stack.addArrangedSubview(loginItemsButton)

        addSection("Git")
        addFullWidth(gitLabel)

        addSection("Mac Cleanup with Mole (Optional)")
        addFullWidth(UIFactory.note(
            "Mole (github.com/tw93/Mole) is a separate, third-party GPL-3.0 tool that you install yourself; "
                + "WCleaner does not include or bundle it. WCleaner only opens Mole in Terminal so you can see and control it. "
                + "Cleanup always starts with a dry run, and running the real cleanup needs a separate confirmation."
        ))
        addFullWidth(moleStatusLabel)
        moleOpenButton = UIFactory.button("Open Mole in Terminal", target: self, action: #selector(openMole))
        molePreviewButton = UIFactory.button("Preview Clean (Dry Run)", target: self, action: #selector(previewMole))
        moleRunButton = UIFactory.button("Run Clean in Terminal…", target: self, action: #selector(runMole))
        stack.addArrangedSubview(UIFactory.hStack([moleOpenButton, molePreviewButton, moleRunButton]))

        addSection("Welcome")
        stack.addArrangedSubview(UIFactory.button("Show Welcome Guide…", target: self, action: #selector(showOnboarding)))
    }

    override func refresh() {
        let settings = model.settings
        if let index = MonitoringInterval.allCases.firstIndex(of: settings.monitoringInterval) {
            intervalPopup.selectItem(at: index)
        }

        let snapshot = model.snapshot
        if snapshot.isScanning {
            lastCheckLabel.stringValue = "Checking now…"
        } else if let completed = snapshot.lastScanCompletedAt {
            var text = EnglishDateFormat.relative(completed)
            if let next = snapshot.nextScanAt {
                text += " · next at \(EnglishDateFormat.time.format(next))"
            }
            lastCheckLabel.stringValue = text
        } else {
            lastCheckLabel.stringValue = "Not checked yet"
        }

        let status = model.launchAtLoginStatus
        launchCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off
        launchStatusLabel.stringValue = "macOS reports: \(status.title)"
        loginItemsButton.isHidden = status != .requiresApproval

        gitLabel.stringValue = model.gitDescription
        gitLabel.textColor = model.gitAvailable ? .secondaryLabelColor : .systemRed

        switch model.moleStatus {
        case .unknown:
            moleStatusLabel.stringValue = "Looking for Mole…"
        case .notInstalled:
            moleStatusLabel.stringValue = "Mole is not installed. Install it yourself with Homebrew (brew install mole) if you want this optional feature."
        case .installed(let path, let version):
            moleStatusLabel.stringValue = "Found Mole \(version ?? "(unknown version)") at \(path)."
        }
        let installed: Bool
        if case .installed = model.moleStatus { installed = true } else { installed = false }
        moleOpenButton.isEnabled = installed
        molePreviewButton.isEnabled = installed
        moleRunButton.isEnabled = installed && model.molePreviewedThisSession
        moleRunButton.toolTip = model.molePreviewedThisSession ? nil : "Run the dry-run preview first."
    }

    @objc private func intervalChanged() {
        let interval = MonitoringInterval.allCases[intervalPopup.indexOfSelectedItem]
        model.settingsStore.update { $0.monitoringInterval = interval }
    }

    @objc private func checkNow() { model.actions?.checkNow() }
    @objc private func launchAtLoginChanged() { model.actions?.setLaunchAtLogin(launchCheckbox.state == .on) }
    @objc private func openLoginItems() { model.actions?.openLoginItemsSettings() }
    @objc private func openMole() { model.actions?.openMole() }
    @objc private func previewMole() { model.actions?.previewMoleClean() }
    @objc private func runMole() { model.actions?.runMoleCleanInTerminal() }
    @objc private func showOnboarding() { model.actions?.showOnboarding() }
}
