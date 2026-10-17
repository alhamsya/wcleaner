import AppKit
import WCleanerCore

/// Modal confirmations for every consequential action. Destructive buttons are never the default.
@MainActor
enum Dialogs {
    // MARK: Consent

    /// Explains the safety rules and requires an explicit acknowledgement before the Allow button works.
    static func requestCleanupConsent(enableAutomaticCleanup: Bool, removalEnabledInBuild: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = enableAutomaticCleanup
            ? "Allow WCleaner to Remove Merged Worktrees Automatically?"
            : "Allow WCleaner to Remove Merged Worktrees?"
        var text = SafetyRulesText.summary
        text += "\n\nPull requests merged before now are never removed automatically; each one needs your review first."
        if !removalEnabledInBuild {
            text += "\n\nThis is a development build: it never removes anything and only shows dry-run decisions."
        }
        alert.informativeText = text

        let acknowledge = NSButton(
            checkboxWithTitle: "I understand that Git deletes the worktree folder; its branch and commits stay in the repository.",
            target: nil,
            action: nil
        )
        acknowledge.lineBreakMode = .byWordWrapping
        acknowledge.translatesAutoresizingMaskIntoConstraints = false
        acknowledge.widthAnchor.constraint(equalToConstant: 380).isActive = true
        alert.accessoryView = acknowledge

        let allow = alert.addButton(withTitle: enableAutomaticCleanup ? "Allow and Turn On" : "Allow")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        allow.keyEquivalent = ""
        allow.isEnabled = false
        let toggler = ButtonEnabler(button: allow)
        acknowledge.target = toggler
        acknowledge.action = #selector(ButtonEnabler.toggle(_:))

        NSApp.activate()
        let response = withExtendedLifetime(toggler) { alert.runModal() }
        return response == .alertFirstButtonReturn && acknowledge.state == .on
    }

    static func confirmWithdrawConsent() -> Bool {
        confirm(
            title: "Withdraw Permission to Remove Worktrees?",
            message: "Automatic cleanup is turned off and WCleaner goes back to dry-run decisions. Reviews you approved are kept.",
            action: "Withdraw",
            destructive: false
        )
    }

    // MARK: Worktrees

    enum ReviewChoice { case allow, openPullRequest, cancel }

    static func review(_ worktree: WorktreeSnapshot, repository: RepositorySnapshot?) -> ReviewChoice {
        let alert = NSAlert()
        alert.messageText = "Review “\(worktree.name)”"
        var lines: [String] = []
        if let repository { lines.append("Repository: \(repository.repository.displayName)") }
        lines.append("Folder: \(worktree.path)")
        lines.append("Branch: \(worktree.branch ?? "none") at \(worktree.shortHead)")
        if let evidence = worktree.decision.evidence {
            lines.append("Pull request #\(evidence.number): \(evidence.title)")
            if let mergedAt = evidence.mergedAt { lines.append("Merged: \(EnglishDateFormat.dateTime.format(mergedAt))") }
        }
        if let added = repository?.repository.addedAt {
            lines.append("Monitoring started: \(EnglishDateFormat.dateTime.format(added))")
        }
        lines.append("")
        lines.append("This pull request was merged before WCleaner started monitoring, so it is never removed without your review. "
            + "Allowing it applies only to this pull request and this exact commit. If automatic cleanup is on, it is removed at the next check "
            + "after every safety check passes again; otherwise you can remove it from the menu.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Allow Cleanup")
        alert.addButton(withTitle: "Open Pull Request")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .allow
        case .alertSecondButtonReturn: return .openPullRequest
        default: return .cancel
        }
    }

    static func confirmRemoval(_ worktree: WorktreeSnapshot, removalEnabledInBuild: Bool) -> Bool {
        var lines = [
            "Folder: \(worktree.path)",
            "Branch: \(worktree.branch ?? "none") at \(worktree.shortHead)",
        ]
        if let evidence = worktree.decision.evidence {
            lines.append("Pull request #\(evidence.number) is merged.")
        }
        lines.append("Estimated size: \(worktree.diskUsage.displayString)")
        for reason in worktree.decision.reasons {
            if case .disposableIgnoredFiles(let paths) = reason {
                lines.append("Ignored files you marked as disposable are deleted with it: \(EligibilityReason.list(paths, limit: 10)).")
            }
        }
        lines.append("")
        lines.append("WCleaner checks everything again with fresh data from Git and GitHub, then runs “git worktree remove” without --force. "
            + "If anything changed, nothing is removed. The branch and its commits stay in the repository.")
        if !removalEnabledInBuild {
            lines.append("")
            lines.append("This development build will stop before removing anything.")
        }
        return confirm(title: "Remove Worktree “\(worktree.name)”?", message: lines.joined(separator: "\n"), action: "Remove Worktree", destructive: true)
    }

    static func showOutcome(_ outcome: CleanupOutcome) {
        let alert = NSAlert()
        let name = (outcome.entry.worktreePath as NSString).lastPathComponent
        switch outcome {
        case .removed:
            alert.messageText = "“\(name)” was removed"
            alert.informativeText = outcome.entry.rationale.joined(separator: "\n")
        case .refused(_, let reasons):
            alert.alertStyle = .warning
            alert.messageText = "“\(name)” was not removed"
            alert.informativeText = "A safety check did not pass:\n" + reasons.map { "• \($0.message)" }.joined(separator: "\n")
        case .failed(let entry):
            alert.alertStyle = .warning
            alert.messageText = "Git did not remove “\(name)”"
            alert.informativeText = (entry.errorMessage ?? "Unknown error.") + "\n\nWCleaner never retries with --force. Check the worktree in Terminal if you want to remove it yourself."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    // MARK: Repositories and accounts

    static func confirmRemoveRepository(_ name: String) -> Bool {
        confirm(
            title: "Stop Monitoring “\(name)”?",
            message: "WCleaner forgets this repository and its account assignment. Nothing on disk is changed.",
            action: "Stop Monitoring",
            destructive: false
        )
    }

    static func confirmDisconnect(_ account: GitHubAccount, assignedRepositories: [String]) -> Bool {
        var message = account.source == .gitHubCLI
            ? "WCleaner stops using this account. GitHub CLI stays logged in; WCleaner never stored its token. Other accounts are not affected."
            : "Its token is deleted from the Keychain on this Mac. Other accounts are not affected."
        if !assignedRepositories.isEmpty {
            message += "\n\nThese repositories use this account and will stop being checked until you assign another account: "
                + assignedRepositories.joined(separator: ", ") + "."
        }
        if account.source == .deviceFlow {
            message += "\n\nTo revoke access completely, also remove WCleaner on GitHub under Settings › Applications."
        }
        return confirm(title: "Disconnect \(account.displayName)?", message: message, action: "Disconnect", destructive: true)
    }

    /// Lets the user pick one of GitHub CLI's logged-in accounts. Returns the chosen login.
    static func chooseGitHubCLIAccount(_ accounts: [GitHubCLIAccount], preselect: String? = nil) -> String? {
        let usable = accounts.filter(\.isUsable)
        guard !usable.isEmpty else {
            showError(
                "No GitHub CLI Account to Use",
                accounts.isEmpty
                    ? "GitHub CLI is not logged in to GitHub.com. Run “gh auth login” in Terminal, then try again."
                    : "GitHub CLI reports a problem with every account. Run “gh auth status” in Terminal for details, log in again with “gh auth login”, then try again."
            )
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "Use a GitHub CLI Login"
        alert.informativeText = "WCleaner will ask GitHub CLI (gh) for this account's token whenever it checks repositories. "
            + "WCleaner does not copy or store that token, and only reads repository and pull request information. "
            + "Use this for organizations where the WCleaner GitHub App is not installed.\n\n"
            + "Note: GitHub CLI tokens usually carry the broad “repo” scope (read and write)."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for account in usable {
            popup.addItem(withTitle: "@" + account.login + (account.isActive ? " (active in gh)" : ""))
            popup.lastItem?.representedObject = account.login
        }
        if let preselect, let index = usable.firstIndex(where: { $0.login.caseInsensitiveCompare(preselect) == .orderedSame }) {
            popup.selectItem(at: index)
        }
        popup.setAccessibilityLabel("GitHub CLI account")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Account")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? String
    }

    static func confirmClearHistory() -> Bool {
        confirm(title: "Clear Cleanup History?", message: "The local log of removals and reviews is deleted. Worktrees and settings are not affected.", action: "Clear History", destructive: true)
    }

    static func confirmMoleClean(_ installation: MoleInstallation) -> Bool {
        confirm(
            title: "Run Mole Clean in Terminal?",
            message: "This runs “mo clean” from \(installation.path) in a Terminal window you can watch and stop with Control-C. "
                + "Mole is a separate tool and decides what to remove; WCleaner does not control or undo it. "
                + "Make sure the dry-run preview showed only what you expect.",
            action: "Run Mole Clean",
            destructive: true
        )
    }

    // MARK: Information

    /// Asks before treating these ignored paths as disposable in every worktree of the repository.
    static func confirmDisposableIgnoredFiles(_ paths: [String], repositoryName: String) -> Bool {
        let shown = paths.prefix(20).map { "• " + $0 }.joined(separator: "\n")
        let more = paths.count > 20 ? "\n• and \(paths.count - 20) more" : ""
        return confirm(
            title: "Allow Deleting These Ignored Files?",
            message: "In every worktree of “\(repositoryName)”, these ignored files and folders will no longer keep the worktree:\n\n"
                + shown + more + "\n\n"
                + "When such a worktree is removed, Git deletes them with it and they cannot be recovered. Only add build output, "
                + "caches and other files you can recreate, never secrets or settings such as .env. Any other ignored file still "
                + "keeps a worktree. You can change the list in Settings › Repositories.",
            action: "Allow Deleting",
            destructive: true
        )
    }

    /// Edits a repository's disposable ignored paths, one per line. Returns the normalized list, or nil when
    /// cancelled or when a line is not an exact relative path.
    static func editDisposableIgnoredPaths(_ current: [String], repositoryName: String) -> [String]? {
        let alert = NSAlert()
        alert.messageText = "Disposable Ignored Files for “\(repositoryName)”"
        alert.informativeText = "Ignored files and folders listed here may be deleted together with a worktree. Write one path per "
            + "line, relative to the worktree’s top folder, exactly as it appears in the worktree (for example “build” or "
            + "“app/node_modules”). Each entry covers that file or folder and everything inside it; wildcards are not allowed. "
            + "Every other ignored file still keeps a worktree."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.autoresizingMask = [.width]
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.string = current.joined(separator: "\n")
        text.setAccessibilityLabel("Disposable ignored paths, one per line")
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let lines = text.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let invalid = lines.filter { DisposablePaths.normalize($0) == nil }
        guard invalid.isEmpty else {
            showError(
                "List Not Saved",
                "These lines are not exact relative paths: \(invalid.prefix(5).joined(separator: ", "))\(invalid.count > 5 ? ", …" : ""). "
                    + "Leave out wildcards, “..”, “.git” and empty folder names."
            )
            return nil
        }
        return DisposablePaths.normalizedList(lines)
    }

    static func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    enum UninstallChoice { case revealData, copy, done }

    static let uninstallSteps = """
    WCleaner never deletes itself. To remove it completely:
    1. In WCleaner Settings › General, turn off “Launch WCleaner at login” (or remove it in System Settings › General › Login Items).
    2. In Settings › Accounts, disconnect each account. This deletes its tokens from the Keychain. You can also search Keychain Access for “WCleaner”.
    3. Choose Quit WCleaner from the menu bar icon.
    4. Move WCleaner.app to the Trash. If you installed it with Homebrew, run: brew uninstall --cask wcleaner
    5. Optional: delete the folder ~/Library/Application Support/WCleaner and run: defaults delete \(AppEnvironment.bundleIdentifier)
    6. Optional: revoke WCleaner on github.com under Settings › Applications.
    Your repositories and worktrees are not touched by any of these steps.
    """

    static func uninstallGuide() -> UninstallChoice {
        let alert = NSAlert()
        alert.messageText = "Uninstall WCleaner"
        alert.informativeText = uninstallSteps
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Show Data Folder")
        alert.addButton(withTitle: "Copy Instructions")
        NSApp.activate()
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .revealData
        case .alertThirdButtonReturn: return .copy
        default: return .done
        }
    }

    // MARK: Helpers

    static func confirm(title: String, message: String, action: String, destructive: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .warning
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: action)
        let cancel = alert.addButton(withTitle: "Cancel")
        if destructive {
            confirm.hasDestructiveAction = true
            confirm.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        } else {
            cancel.keyEquivalent = "\u{1b}"
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Enables a button only while a checkbox is on.
@MainActor
private final class ButtonEnabler: NSObject {
    private weak var button: NSButton?

    init(button: NSButton) {
        self.button = button
    }

    @objc func toggle(_ sender: NSButton) {
        button?.isEnabled = sender.state == .on
    }
}
