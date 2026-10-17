import AppKit
import WCleanerCore

/// Selectors the status menu sends. Implemented by `StatusItemController`.
@MainActor
@objc protocol StatusMenuTarget: AnyObject {
    func checkNow(_ sender: Any?)
    func openSettings(_ sender: Any?)
    func openHistory(_ sender: Any?)
    func togglePause(_ sender: Any?)
    func addRepository(_ sender: Any?)
    func revealPath(_ sender: NSMenuItem)
    func copyPath(_ sender: NSMenuItem)
    func openURL(_ sender: NSMenuItem)
    func reviewWorktree(_ sender: NSMenuItem)
    func removeWorktree(_ sender: NSMenuItem)
    func allowDisposableIgnoredFiles(_ sender: NSMenuItem)
    func openRepositorySettings(_ sender: Any?)
    func quit(_ sender: Any?)
}

/// Builds the native status menu from a snapshot. Pure construction: no I/O, no timers.
@MainActor
struct StatusMenuBuilder {
    let snapshot: MonitorSnapshot
    let settings: AppSettings
    let accounts: [GitHubAccount]
    let gitAvailable: Bool
    let gitDescription: String
    let now: Date
    weak var target: (any StatusMenuTarget)?

    /// Tags that delimit the part of the menu that is rebuilt while the menu stays open.
    static let summaryTag = 9_001
    static let footerTag = 9_002

    /// Fills the menu and returns its summary card, which the caller may refresh while the menu is open.
    @discardableResult
    func populate(_ menu: NSMenu) -> MenuSummaryView {
        menu.removeAllItems()
        let summaryView = MenuSummaryView(summary: MenuSummary(snapshot: snapshot, settings: settings, now: now))
        summaryView.onCheckNow = { [weak target] in target?.checkNow(nil) }
        let summaryItem = NSMenuItem(title: "WCleaner", action: nil, keyEquivalent: "")
        summaryItem.view = summaryView
        summaryItem.tag = Self.summaryTag
        menu.addItem(summaryItem)
        for item in bodyItems() { menu.addItem(item) }
        addFooter(to: menu)
        return summaryView
    }

    /// Replaces the warnings and repository rows of an open menu in place (after a check finished).
    /// Returns false when the menu does not have the expected structure.
    @discardableResult
    func replaceBody(in menu: NSMenu) -> Bool {
        let summaryIndex = menu.indexOfItem(withTag: Self.summaryTag)
        let footerIndex = menu.indexOfItem(withTag: Self.footerTag)
        guard summaryIndex >= 0, footerIndex > summaryIndex else { return false }
        for index in stride(from: footerIndex - 1, to: summaryIndex, by: -1) {
            menu.removeItem(at: index)
        }
        for (offset, item) in bodyItems().enumerated() {
            menu.insertItem(item, at: summaryIndex + 1 + offset)
        }
        return true
    }

    // MARK: Body

    /// Warnings, then one row per repository and linked worktree.
    private func bodyItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !gitAvailable {
            items.append(Self.infoItem(Self.warning(gitDescription), toolTip: gitDescription))
        }
        if let error = snapshot.lastScanError {
            items.append(Self.infoItem(Self.warning(error), toolTip: error))
        }
        items.append(.separator())

        guard !snapshot.repositories.isEmpty else {
            items.append(Self.infoItem(Self.secondary("No repositories yet")))
            items.append(actionItem("Add Repository…", #selector(StatusMenuTarget.addRepository(_:))))
            return items
        }
        for repository in snapshot.repositories {
            items.append(repositoryItem(repository))
            if let error = repository.error {
                let errorItem = Self.infoItem(Self.warning(error), toolTip: error)
                errorItem.indentationLevel = 1
                items.append(errorItem)
            }
            let linked = repository.linkedWorktrees
            if linked.isEmpty && repository.error == nil {
                let empty = Self.infoItem(Self.secondary("No linked worktrees"))
                empty.indentationLevel = 1
                items.append(empty)
            }
            for worktree in linked {
                items.append(worktreeItem(worktree, repository: repository))
            }
        }
        return items
    }

    private func repositoryItem(_ repository: RepositorySnapshot) -> NSMenuItem {
        let title = NSMutableAttributedString(attributedString: Self.styled(repository.repository.displayName, font: .boldSystemFont(ofSize: NSFont.systemFontSize)))
        var detail: [String] = []
        if let github = repository.githubRepository { detail.append(github.fullName) }
        detail.append(accountSummary(repository.accountResolution))
        title.append(Self.secondary("  " + detail.joined(separator: " · ")))

        let item = NSMenuItem(title: repository.repository.displayName, action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.image = Self.coloredSymbol("folder.fill", color: .controlAccentColor, description: "Repository")
        item.setAccessibilityLabel("Repository \(repository.repository.displayName), \(detail.joined(separator: ", "))")

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(Self.infoItem(Self.plain("Path: \(repository.repository.path.abbreviatedPath)"), toolTip: repository.repository.path))
        if let github = repository.githubRepository {
            let githubItem = actionItem("GitHub: \(github.fullName)", #selector(StatusMenuTarget.openURL(_:)))
            githubItem.representedObject = github.htmlURL
            submenu.addItem(githubItem)
        }
        submenu.addItem(Self.infoItem(Self.plain("Account: \(accountDetail(repository.accountResolution))")))
        submenu.addItem(.separator())
        let reveal = actionItem("Reveal in Finder", #selector(StatusMenuTarget.revealPath(_:)))
        reveal.representedObject = repository.repository.path
        submenu.addItem(reveal)
        submenu.addItem(actionItem("Repository Settings…", #selector(StatusMenuTarget.openRepositorySettings(_:))))
        item.submenu = submenu
        return item
    }

    private func worktreeItem(_ worktree: WorktreeSnapshot, repository: RepositorySnapshot) -> NSMenuItem {
        let decision = worktree.decision
        // Name, pull request and size in aligned columns.
        let title = NSMutableAttributedString(attributedString: Self.plain(Self.truncateMiddle(worktree.branch ?? worktree.name, 24)))
        title.append(NSAttributedString(string: "\t" + Self.compactPullRequest(worktree.pullRequest), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: Self.pullRequestColor(worktree.pullRequest),
        ]))
        title.append(Self.secondary("\t" + worktree.diskUsage.displayString))
        let columns = NSMutableParagraphStyle()
        columns.tabStops = [
            NSTextTab(textAlignment: .left, location: 175),
            NSTextTab(textAlignment: .right, location: 355),
        ]
        title.addAttribute(.paragraphStyle, value: columns, range: NSRange(location: 0, length: title.length))

        let item = NSMenuItem(title: worktree.branch ?? worktree.name, action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.indentationLevel = 1
        item.image = Self.verdictImage(decision)
        item.toolTip = decision.summary
        item.setAccessibilityLabel("Worktree \(worktree.branch ?? worktree.name): \(decision.title). \(decision.summary)")

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(Self.infoItem(Self.plain("Path: \(worktree.path.abbreviatedPath)"), toolTip: worktree.path))
        submenu.addItem(Self.infoItem(Self.plain("Branch: \(worktree.branch ?? "none (detached)")")))
        submenu.addItem(Self.infoItem(Self.plain("HEAD: \(worktree.shortHead)"), toolTip: worktree.head))
        if let evidence = worktree.pullRequest?.evidence {
            let prItem = actionItem("PR #\(evidence.number): \(Self.truncate(evidence.title, 60)) — \(evidence.state.title)", #selector(StatusMenuTarget.openURL(_:)))
            prItem.representedObject = evidence.url
            prItem.toolTip = evidence.title
            submenu.addItem(prItem)
        } else {
            submenu.addItem(Self.infoItem(Self.plain("Pull request: \(pullRequestSummary(worktree.pullRequest))")))
        }
        submenu.addItem(Self.infoItem(Self.plain("Size: \(worktree.diskUsage.displayString)\(worktree.diskUsage.bytes != nil ? " (estimated)" : "")")))
        submenu.addItem(.separator())

        submenu.addItem(Self.infoItem(Self.styled(decision.title, font: .boldSystemFont(ofSize: NSFont.systemFontSize))))
        let reasons = decision.reasons.isEmpty ? [decision.summary] : decision.reasons.map(\.message)
        for reason in reasons.prefix(8) {
            submenu.addItem(Self.infoItem(Self.secondary("• " + Self.truncate(reason, 90)), toolTip: reason))
        }
        if reasons.count > 8 {
            submenu.addItem(Self.infoItem(Self.secondary("• and \(reasons.count - 8) more…")))
        }
        submenu.addItem(.separator())

        let reveal = actionItem("Reveal in Finder", #selector(StatusMenuTarget.revealPath(_:)))
        reveal.representedObject = worktree.path
        reveal.isEnabled = worktree.inspection?.exists ?? true
        submenu.addItem(reveal)
        let copy = actionItem("Copy Path", #selector(StatusMenuTarget.copyPath(_:)))
        copy.representedObject = worktree.path
        submenu.addItem(copy)
        if decision.verdict == .needsReview {
            let review = actionItem("Review and Allow Cleanup…", #selector(StatusMenuTarget.reviewWorktree(_:)))
            review.representedObject = worktree
            submenu.addItem(review)
        }
        if Self.listsEveryIgnoredFile(decision) {
            let allow = actionItem("Allow Deleting These Ignored Files…", #selector(StatusMenuTarget.allowDisposableIgnoredFiles(_:)))
            allow.representedObject = worktree
            submenu.addItem(allow)
        }
        if decision.isSafeToRemove {
            let remove = actionItem("Remove Worktree Now…", #selector(StatusMenuTarget.removeWorktree(_:)))
            remove.representedObject = worktree
            submenu.addItem(remove)
        }
        item.submenu = submenu
        return item
    }

    /// True when the decision lists every ignored file that keeps the worktree, so they can be offered as disposable.
    static func listsEveryIgnoredFile(_ decision: CleanupDecision) -> Bool {
        decision.reasons.contains { reason in
            if case .ignoredFiles(let count, let paths) = reason { !paths.isEmpty && paths.count == count } else { false }
        }
    }

    // MARK: Footer

    private func addFooter(to menu: NSMenu) {
        // Check Now is a button in the summary card, so checking does not close the menu.
        let separator = NSMenuItem.separator()
        separator.tag = Self.footerTag
        menu.addItem(separator)
        if settings.autoCleanupEnabled {
            menu.addItem(actionItem(settings.autoCleanupPaused ? "Resume Automatic Cleanup" : "Pause Automatic Cleanup", #selector(StatusMenuTarget.togglePause(_:))))
        }
        menu.addItem(actionItem("View History…", #selector(StatusMenuTarget.openHistory(_:)), key: "y"))
        menu.addItem(actionItem("Settings…", #selector(StatusMenuTarget.openSettings(_:)), key: ","))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit WCleaner", #selector(StatusMenuTarget.quit(_:)), key: "q"))
    }

    // MARK: Text

    private func pullRequestSummary(_ match: PullRequestMatch?) -> String {
        match?.summary ?? "PR not checked"
    }

    private func accountSummary(_ resolution: AccountResolution) -> String {
        if case .assigned(let id, _) = resolution {
            return accounts.first { $0.id == id }.map { "@\($0.login)" } ?? "account \(id.userID)"
        }
        return resolution.title
    }

    private func accountDetail(_ resolution: AccountResolution) -> String {
        switch resolution {
        case .accountUnavailable(_, let reason): "\(accountSummary(resolution)) — \(reason)"
        case .notGitHub(let detail), .unverified(let detail): "\(resolution.title) — \(detail)"
        default: accountSummary(resolution)
        }
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    static func infoItem(_ title: NSAttributedString, toolTip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title.string, action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.isEnabled = false
        item.toolTip = toolTip
        return item
    }

    static func verdictImage(_ decision: CleanupDecision) -> NSImage? {
        let (name, description): (String, String) = switch decision.verdict {
        case .eligible: ("checkmark.circle.fill", "Safe to remove")
        case .waiting: ("clock.circle.fill", "Waiting for cleanup delay")
        case .needsReview: ("eye.circle.fill", "Needs review")
        case .blocked: ("lock.circle.fill", "Kept")
        }
        return coloredSymbol(name, color: VerdictStyle.color(decision.verdict), description: description)
    }

    /// An SF Symbol in a fixed colour (not a template), so status reads at a glance. Circle symbols get a
    /// white glyph (check mark, lock…) on a solid coloured circle, which stays legible in light and dark menus.
    static func coloredSymbol(_ name: String, color: NSColor, description: String) -> NSImage? {
        let colors = name.hasSuffix(".circle.fill")
            ? NSImage.SymbolConfiguration(paletteColors: [.white, color])
            : NSImage.SymbolConfiguration(hierarchicalColor: color)
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(colors)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
    }

    /// Short pull request label for a worktree row, e.g. "#12 Merged".
    static func compactPullRequest(_ match: PullRequestMatch?) -> String {
        switch match {
        case .matched(let evidence): "#\(evidence.number) \(evidence.state.title)"
        case .headMismatch(let evidence, _): "#\(evidence.number) other HEAD"
        case .ambiguous(let numbers): "\(numbers.count) possible PRs"
        case .notFound: "No PR"
        case .unavailable: "PR unavailable"
        case .none: "Not checked"
        }
    }

    /// GitHub-like colours: merged purple, open green, closed red; uncertain states orange.
    static func pullRequestColor(_ match: PullRequestMatch?) -> NSColor {
        switch match {
        case .matched(let evidence):
            switch evidence.state {
            case .merged: .systemPurple
            case .open: .systemGreen
            case .closedUnmerged: .systemRed
            case .unknown: .systemOrange
            }
        case .headMismatch, .ambiguous, .unavailable: .systemOrange
        case .notFound, .none: .secondaryLabelColor
        }
    }

    static func styled(_ text: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font])
    }

    static func plain(_ text: String) -> NSAttributedString {
        styled(text, font: .menuFont(ofSize: 0))
    }

    static func secondary(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    static func warning(_ text: String) -> NSAttributedString {
        NSAttributedString(string: "⚠︎ " + truncate(text, 90), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.systemOrange,
        ])
    }

    static func truncateMiddle(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(limit - 1 - head))
    }

    static func truncate(_ text: String, _ limit: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit - 1)) + "…" : singleLine
    }
}
