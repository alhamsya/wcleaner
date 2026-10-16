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

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        addHeader(to: menu)
        menu.addItem(.separator())
        addRepositories(to: menu)
        menu.addItem(.separator())
        addFooter(to: menu)
    }

    // MARK: Header

    private func addHeader(to menu: NSMenu) {
        menu.addItem(Self.infoItem(Self.styled("WCleaner", font: .boldSystemFont(ofSize: NSFont.systemFontSize))))

        let status: String
        if snapshot.isScanning {
            status = "Checking repositories…"
        } else if let completed = snapshot.lastScanCompletedAt {
            var text = "Last checked \(EnglishDateFormat.relative(completed, now: now))"
            if let next = snapshot.nextScanAt, next > now {
                text += " · next at \(EnglishDateFormat.time.format(next))"
            }
            status = text
        } else {
            status = "Not checked yet"
        }
        menu.addItem(Self.infoItem(Self.secondary(status)))

        if !gitAvailable {
            menu.addItem(Self.infoItem(Self.warning(gitDescription), toolTip: gitDescription))
        }
        if let error = snapshot.lastScanError {
            menu.addItem(Self.infoItem(Self.warning(error), toolTip: error))
        }

        let worktrees = snapshot.allLinkedWorktrees
        if !worktrees.isEmpty {
            let usage = "\(worktrees.count) linked worktree\(worktrees.count == 1 ? "" : "s") · \(snapshot.totalUsage.displayString) estimated"
            menu.addItem(Self.infoItem(Self.secondary(usage)))
            let safe = worktrees.filter { $0.decision.isSafeToRemove }
            if !safe.isEmpty {
                let opportunity = "Cleanup opportunity: \(safe.count) worktree\(safe.count == 1 ? "" : "s") · \(snapshot.cleanupOpportunity.displayString)"
                menu.addItem(Self.infoItem(Self.secondary(opportunity)))
            }
        }

        let automatic: String
        if !settings.autoCleanupEnabled {
            automatic = "Automatic cleanup: Off (dry run)"
        } else if settings.autoCleanupPaused {
            automatic = "Automatic cleanup: Paused"
        } else {
            automatic = "Automatic cleanup: On"
        }
        menu.addItem(Self.infoItem(Self.secondary(automatic)))
    }

    // MARK: Repositories

    private func addRepositories(to menu: NSMenu) {
        guard !snapshot.repositories.isEmpty else {
            menu.addItem(Self.infoItem(Self.secondary("No repositories yet")))
            menu.addItem(actionItem("Add Repository…", #selector(StatusMenuTarget.addRepository(_:))))
            return
        }
        for repository in snapshot.repositories {
            menu.addItem(repositoryItem(repository))
            if let error = repository.error {
                let errorItem = Self.infoItem(Self.warning(error), toolTip: error)
                errorItem.indentationLevel = 1
                menu.addItem(errorItem)
            }
            let linked = repository.linkedWorktrees
            if linked.isEmpty && repository.error == nil {
                let empty = Self.infoItem(Self.secondary("No linked worktrees"))
                empty.indentationLevel = 1
                menu.addItem(empty)
            }
            for worktree in linked {
                menu.addItem(worktreeItem(worktree, repository: repository))
            }
        }
    }

    private func repositoryItem(_ repository: RepositorySnapshot) -> NSMenuItem {
        let title = NSMutableAttributedString(attributedString: Self.styled(repository.repository.displayName, font: .boldSystemFont(ofSize: NSFont.systemFontSize)))
        var detail: [String] = []
        if let github = repository.githubRepository { detail.append(github.fullName) }
        detail.append(accountSummary(repository.accountResolution))
        title.append(Self.secondary("  " + detail.joined(separator: " · ")))

        let item = NSMenuItem(title: repository.repository.displayName, action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.image = UIFactory.symbol("folder", description: "Repository")
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
        let title = NSMutableAttributedString(attributedString: Self.plain(worktree.branch ?? worktree.name))
        title.append(Self.secondary("  " + [pullRequestSummary(worktree.pullRequest), worktree.diskUsage.displayString].joined(separator: " · ")))

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
        if decision.isSafeToRemove {
            let remove = actionItem("Remove Worktree Now…", #selector(StatusMenuTarget.removeWorktree(_:)))
            remove.representedObject = worktree
            submenu.addItem(remove)
        }
        item.submenu = submenu
        return item
    }

    // MARK: Footer

    private func addFooter(to menu: NSMenu) {
        let check = actionItem(snapshot.isScanning ? "Checking…" : "Check Now", #selector(StatusMenuTarget.checkNow(_:)), key: "r")
        menu.addItem(check)
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
        switch match {
        case .matched(let evidence): "PR #\(evidence.number) \(evidence.state.title)"
        case .headMismatch(let evidence, _): "PR #\(evidence.number) \(evidence.state.title), different HEAD"
        case .ambiguous(let numbers): "\(numbers.count) possible PRs"
        case .notFound: "No PR"
        case .unavailable: "PR status unavailable"
        case .none: "PR not checked"
        }
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
        case .eligible: ("checkmark.circle", "Safe to remove")
        case .waiting: ("clock", "Waiting for cleanup delay")
        case .needsReview: ("eye", "Needs review")
        case .blocked: ("lock", "Kept")
        }
        return UIFactory.symbol(name, description: description)
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

    static func truncate(_ text: String, _ limit: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit - 1)) + "…" : singleLine
    }
}
