import AppKit
import WCleanerCore

/// First-run guide. Nothing destructive is enabled here: removal permission has its own consent dialog.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    /// `confirmed` is false when the window was closed without pressing Done; nothing is turned on then.
    private let onFinish: (_ confirmed: Bool, _ launchAtLogin: Bool, _ notifications: Bool) -> Void
    private var launchCheckbox: NSButton!
    private var notificationsCheckbox: NSButton!
    private var finished = false
    private var confirmed = false

    init(model: AppModel, onFinish: @escaping (_ confirmed: Bool, _ launchAtLogin: Bool, _ notifications: Bool) -> Void) {
        self.model = model
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to WCleaner"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent() {
        let title = UIFactory.label("Welcome to WCleaner", font: .systemFont(ofSize: 20, weight: .semibold))
        let intro = UIFactory.wrapping(
            "WCleaner lives in your menu bar. It finds the Git worktrees of repositories you add, shows their pull request status, "
                + "and can remove worktrees whose pull requests are verifiably merged. Until you allow removal, everything is a dry run."
        )

        let accounts = step(
            number: 1,
            text: model.gitHubClientConfigured
                ? "Connect one or more GitHub accounts. WCleaner uses each account only to read repositories and pull requests."
                : "GitHub sign-in is not configured in this build (no GitHub App client ID). See GITHUB_APP_SETUP.md.",
            button: UIFactory.button("Open Accounts…", target: self, action: #selector(openAccounts))
        )
        let repositories = step(
            number: 2,
            text: "Add the repositories you want WCleaner to watch. Only repositories you add are ever checked.",
            button: UIFactory.button("Add Repository…", target: self, action: #selector(addRepository))
        )
        let consent = step(
            number: 3,
            text: "Optional: review the safety rules and allow WCleaner to remove merged worktrees.",
            button: UIFactory.button("Review Safety Rules…", target: self, action: #selector(reviewSafety))
        )

        launchCheckbox = UIFactory.checkbox("Launch WCleaner at login", target: nil, action: nil)
        launchCheckbox.state = model.settings.launchAtLoginDesired ? .on : .off
        notificationsCheckbox = UIFactory.checkbox("Show notifications (macOS will ask for permission)", target: nil, action: nil)
        notificationsCheckbox.state = model.settings.notificationsEnabled ? .on : .off

        let done = UIFactory.button("Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, intro, accounts, repositories, consent, UIFactory.separator(), launchCheckbox, notificationsCheckbox, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        stack.setCustomSpacing(18, after: intro)
        for view in [intro, accounts, repositories, consent] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 468).isActive = true
        }
        window?.contentView = stack
    }

    private func step(number: Int, text: String, button: NSButton) -> NSView {
        let badge = UIFactory.label("\(number)", font: .systemFont(ofSize: 15, weight: .bold))
        let label = UIFactory.wrapping(text)
        label.preferredMaxLayoutWidth = 300
        let row = UIFactory.hStack([badge, label, button], spacing: 12)
        row.alignment = .centerY
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Used when the app quits: the guide is shown again next launch instead of being recorded as finished.
    func dismissWithoutRecording() {
        finished = true
        close()
    }

    @objc private func openAccounts() { model.actions?.openSettings(.accounts) }
    @objc private func addRepository() { model.actions?.addRepository() }
    @objc private func reviewSafety() { model.actions?.requestCleanupConsent(enableAutomaticCleanup: false) }

    @objc private func done() {
        confirmed = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onFinish(confirmed, launchCheckbox.state == .on, notificationsCheckbox.state == .on)
    }
}
