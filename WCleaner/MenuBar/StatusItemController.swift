import AppKit
import WCleanerCore

/// Owns the `NSStatusItem`. The menu is rebuilt lazily in `menuNeedsUpdate(_:)`, only when opened,
/// so an idle WCleaner does no menu work at all.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, StatusMenuTarget {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let model: AppModel
    private var observation: AppModel.Token?
    private var showsAttention = false
    private let animator = StatusIconAnimator()
    /// The summary card of the open menu, refreshed in place while the menu stays open.
    private weak var openSummaryView: MenuSummaryView?
    /// What the open menu's repository rows were built from; they are rebuilt when it changes.
    private var shownBody: BodyInputs?

    private struct BodyInputs: Equatable {
        var repositories: [RepositorySnapshot]
        var lastScanError: String?
        var gitAvailable: Bool
        var accounts: [GitHubAccount]
    }

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = StatusIcon.image()
            button.toolTip = "WCleaner"
            button.setAccessibilityLabel("WCleaner")
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        animator.onFrame = { [weak self] _ in self?.renderIcon() }
        observation = model.observe { [weak self] change in
            guard let self else { return }
            if change == .snapshot || change == .repositories {
                // Nothing moves when there is nothing to check.
                animator.setChecking(model.snapshot.isScanning && !model.repositories.isEmpty)
            }
            if change == .snapshot || change == .accounts || change == .system {
                updateIcon()
            }
            if change == .snapshot || change == .settings {
                openSummaryView?.apply(MenuSummary(snapshot: model.snapshot, settings: model.settings, now: Date()))
            }
            if openSummaryView != nil, change == .snapshot || change == .accounts || change == .system {
                refreshOpenMenuBody()
            }
        }
    }

    private var bodyInputs: BodyInputs {
        BodyInputs(
            repositories: model.snapshot.repositories,
            lastScanError: model.snapshot.lastScanError,
            gitAvailable: model.gitAvailable,
            accounts: model.accounts
        )
    }

    private func makeBuilder() -> StatusMenuBuilder {
        StatusMenuBuilder(
            snapshot: model.snapshot,
            settings: model.settings,
            accounts: model.accounts,
            gitAvailable: model.gitAvailable,
            gitDescription: model.gitDescription,
            now: Date(),
            target: self
        )
    }

    /// Rebuilds the repository rows of the open menu, e.g. when a check started from the menu finished.
    private func refreshOpenMenuBody() {
        let inputs = bodyInputs
        guard inputs != shownBody else { return }
        if makeBuilder().replaceBody(in: menu) { shownBody = inputs }
    }

    func invalidate() {
        animator.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Plays the short sparkle on the menu bar icon after a worktree was removed.
    func celebrateCleanup() {
        animator.playSparkle()
    }

    private func updateIcon() {
        let attention = model.snapshot.needsAttention || !model.gitAvailable
            || model.accounts.contains { !$0.state.isConnected }
        guard attention != showsAttention else { return }
        showsAttention = attention
        renderIcon()
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        let image = StatusIcon.image(showsAttention ? .attention : .normal, effect: animator.effect)
        button.image = image
        button.setAccessibilityLabel(image.accessibilityDescription)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        openSummaryView = makeBuilder().populate(menu)
        shownBody = bodyInputs
    }

    func menuWillOpen(_ menu: NSMenu) {
        openSummaryView?.playEntrance()
    }

    func menuDidClose(_ menu: NSMenu) {
        openSummaryView = nil
        shownBody = nil
    }

    // MARK: StatusMenuTarget

    func checkNow(_ sender: Any?) { model.actions?.checkNow() }
    func openSettings(_ sender: Any?) { model.actions?.openSettings(nil) }
    func openHistory(_ sender: Any?) { model.actions?.openSettings(.history) }
    func openRepositorySettings(_ sender: Any?) { model.actions?.openSettings(.repositories) }
    func addRepository(_ sender: Any?) { model.actions?.addRepository() }
    func quit(_ sender: Any?) { model.actions?.quit() }

    func togglePause(_ sender: Any?) {
        model.actions?.setAutomaticCleanupPaused(!model.settings.autoCleanupPaused)
    }

    func revealPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openURL(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String,
              let url = URL(string: string),
              url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func reviewWorktree(_ sender: NSMenuItem) {
        guard let worktree = sender.representedObject as? WorktreeSnapshot else { return }
        model.actions?.reviewWorktree(worktree)
    }

    func removeWorktree(_ sender: NSMenuItem) {
        guard let worktree = sender.representedObject as? WorktreeSnapshot else { return }
        model.actions?.removeWorktreeManually(worktree)
    }

    func allowDisposableIgnoredFiles(_ sender: NSMenuItem) {
        guard let worktree = sender.representedObject as? WorktreeSnapshot else { return }
        model.actions?.allowDisposableIgnoredFiles(worktree)
    }
}
