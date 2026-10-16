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
        observation = model.observe { [weak self] change in
            if change == .snapshot || change == .accounts || change == .system {
                self?.updateIcon()
            }
        }
    }

    func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateIcon() {
        let attention = model.snapshot.needsAttention || !model.gitAvailable
            || model.accounts.contains { !$0.state.isConnected }
        guard attention != showsAttention, let button = statusItem.button else { return }
        showsAttention = attention
        button.image = StatusIcon.image(attention ? .attention : .normal)
        button.setAccessibilityLabel(attention ? "WCleaner, needs attention" : "WCleaner")
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        StatusMenuBuilder(
            snapshot: model.snapshot,
            settings: model.settings,
            accounts: model.accounts,
            gitAvailable: model.gitAvailable,
            gitDescription: model.gitDescription,
            now: Date(),
            target: self
        ).populate(menu)
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
}
