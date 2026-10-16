import AppKit
import WCleanerCore

@MainActor
final class NotificationsPaneController: SettingsPaneViewController {
    private var enabledCheckbox: NSButton!
    private let permissionLabel = UIFactory.note("")
    private var openSettingsButton: NSButton!
    private var testButton: NSButton!

    override func buildContent() {
        addSection("Notifications")
        enabledCheckbox = UIFactory.checkbox("Notify me when a worktree is cleaned up or a cleanup fails", target: self, action: #selector(toggled))
        stack.addArrangedSubview(enabledCheckbox)
        addFullWidth(permissionLabel)
        openSettingsButton = UIFactory.button("Open Notification Settings…", target: self, action: #selector(openSettings))
        testButton = UIFactory.button("Send Test Notification", target: self, action: #selector(sendTest))
        stack.addArrangedSubview(UIFactory.hStack([openSettingsButton, testButton]))
        addFullWidth(UIFactory.note(
            "Notifications name the repository, branch and pull request number. They never include tokens or file contents. "
                + "macOS decides whether WCleaner may show notifications; this setting only controls whether WCleaner asks to send them."
        ))
    }

    override func refresh() {
        enabledCheckbox.state = model.settings.notificationsEnabled ? .on : .off
        permissionLabel.stringValue = "macOS permission: \(model.notificationAuthorization.title)"
        permissionLabel.textColor = model.notificationAuthorization == .denied ? .systemOrange : .secondaryLabelColor
        testButton.isEnabled = model.settings.notificationsEnabled && model.notificationAuthorization == .authorized
    }

    @objc private func toggled() { model.actions?.setNotificationsEnabled(enabledCheckbox.state == .on) }
    @objc private func openSettings() { model.actions?.openNotificationSettings() }
    @objc private func sendTest() { model.actions?.sendTestNotification() }
}
