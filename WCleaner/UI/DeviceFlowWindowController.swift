import AppKit
import WCleanerCore

/// Shows GitHub's device-flow code while WCleaner waits for the user to authorize in the browser.
/// It opens only the verification page GitHub returned, and only if it is on the expected HTTPS host.
@MainActor
final class DeviceFlowWindowController: NSWindowController, NSWindowDelegate {
    private let authorization: DeviceAuthorization
    private let allowedHost: String
    private let onCancel: () -> Void
    private let statusLabel = UIFactory.note("Waiting for you to authorize WCleaner on GitHub…")
    private let spinner = NSProgressIndicator()
    private var finished = false

    init(authorization: DeviceAuthorization, allowedHost: String, isReconnect: Bool, onCancel: @escaping () -> Void) {
        self.authorization = authorization
        self.allowedHost = allowedHost.lowercased()
        self.onCancel = onCancel
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = isReconnect ? "Reconnect GitHub Account" : "Connect GitHub Account"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent(isReconnect: isReconnect)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(isReconnect: Bool) {
        let intro = UIFactory.label(isReconnect
            ? "Sign in on GitHub as the same account to reconnect it."
            : "Sign in on GitHub with the account you want to add.")
        let step = UIFactory.note("1. Copy this code.  2. Open GitHub and enter it.  3. Approve WCleaner.")

        let code = NSTextField(labelWithString: authorization.userCode)
        code.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        code.isSelectable = true
        code.alignment = .center
        code.setAccessibilityLabel("Device code \(authorization.userCode.map(String.init).joined(separator: " "))")

        let copy = UIFactory.button("Copy Code", target: self, action: #selector(copyCode))
        let open = UIFactory.button("Open GitHub", target: self, action: #selector(openGitHub))
        open.keyEquivalent = "\r"
        let cancel = UIFactory.button("Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let expires = UIFactory.note("The code expires at \(EnglishDateFormat.time.format(authorization.expiresAt)).")

        let stack = NSStackView(views: [
            intro,
            step,
            code,
            UIFactory.hStack([copy, open]),
            UIFactory.hStack([spinner, statusLabel]),
            expires,
            cancel,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.preferredMaxLayoutWidth = 360
        window?.contentView = stack
    }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window after success or failure, without triggering the cancel callback.
    func finish() {
        finished = true
        spinner.stopAnimation(nil)
        close()
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.userCode, forType: .string)
        statusLabel.stringValue = "Code copied. Waiting for you to authorize WCleaner on GitHub…"
    }

    @objc private func openGitHub() {
        let url = authorization.verificationURI
        guard url.scheme == "https", url.host?.lowercased() == allowedHost else {
            statusLabel.stringValue = "GitHub returned an unexpected sign-in address, so WCleaner did not open it."
            statusLabel.textColor = .systemRed
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func cancel() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
