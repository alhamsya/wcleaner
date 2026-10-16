import AppKit

/// The Settings tabs, shown as a horizontal icon toolbar across the top of the window.
enum SettingsTab: String, CaseIterable {
    case general
    case accounts
    case repositories
    case autoCleanup
    case notifications
    case appearance
    case history
    case about

    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .repositories: "Repositories"
        case .autoCleanup: "Auto Cleanup"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .repositories: "folder"
        case .autoCleanup: "sparkles"
        case .notifications: "bell.badge"
        case .appearance: "circle.lefthalf.filled"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("WCleaner.Settings." + rawValue) }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        let prefix = "WCleaner.Settings."
        guard toolbarIdentifier.rawValue.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(toolbarIdentifier.rawValue.dropFirst(prefix.count)))
    }
}

/// Base class for one Settings pane: a vertical stack with standard insets and a fixed width.
@MainActor
class SettingsPaneViewController: NSViewController {
    static let contentWidth: CGFloat = 640

    let stack = NSStackView()
    let model: AppModel
    private var observation: AppModel.Token?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        view = root
        buildContent()
        refresh()
        observation = model.observe { [weak self] change in
            guard let self, self.isViewLoaded else { return }
            if self.shouldRefresh(for: change) {
                self.refresh()
            }
        }
    }

    /// Subclasses add their controls here.
    func buildContent() {}

    /// Subclasses update their controls from the model here.
    func refresh() {}

    func shouldRefresh(for change: AppModel.Change) -> Bool { true }

    /// Adds a view that spans the full content width (needed for wrapping text and tables).
    func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    func addSection(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            addFullWidth(UIFactory.separator())
        }
        stack.addArrangedSubview(UIFactory.sectionHeader(title))
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let model: AppModel
    private let makePane: (SettingsTab) -> SettingsPaneViewController
    private var panes: [SettingsTab: SettingsPaneViewController] = [:]
    private(set) var selectedTab: SettingsTab = .general

    init(model: AppModel, makePane: @escaping (SettingsTab) -> SettingsPaneViewController) {
        self.model = model
        self.makePane = makePane
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsPaneViewController.contentWidth, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.titleVisibility = .visible
        window.setFrameAutosaveName("WCleanerSettings")
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "WCleanerSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        select(.general, animate: false)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(tab: SettingsTab? = nil) {
        if let tab {
            select(tab, animate: window?.isVisible == true)
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func pane(for tab: SettingsTab) -> SettingsPaneViewController {
        if let pane = panes[tab] { return pane }
        let pane = makePane(tab)
        panes[tab] = pane
        return pane
    }

    func select(_ tab: SettingsTab, animate: Bool) {
        guard let window else { return }
        selectedTab = tab
        window.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
        window.title = tab.title

        let pane = pane(for: tab)
        let paneView = pane.view
        paneView.layoutSubtreeIfNeeded()
        let fitting = paneView.fittingSize
        let contentSize = NSSize(width: SettingsPaneViewController.contentWidth, height: max(160, ceil(fitting.height)))

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height

        paneView.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = paneView
        window.setFrame(frame, display: true, animate: animate)
        window.recalculateKeyViewLoop()
        pane.refresh()
    }

    /// Re-fits the window after a pane changed its content height.
    func resizeToFitSelectedPane() {
        select(selectedTab, animate: true)
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(toolbarIdentifier: sender.itemIdentifier) else { return }
        select(tab, animate: true)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = SettingsTab(toolbarIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.toolTip = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        item.isBordered = false
        return item
    }
}
