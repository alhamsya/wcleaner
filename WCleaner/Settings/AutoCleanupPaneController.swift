import AppKit
import WCleanerCore

@MainActor
final class AutoCleanupPaneController: SettingsPaneViewController {
    private var enableCheckbox: NSButton!
    private var pauseCheckbox: NSButton!
    private var delayPopup: NSPopUpButton!
    private let consentLabel = UIFactory.note("")
    private let buildLabel = UIFactory.note("", color: .systemOrange)
    private var consentButton: NSButton!
    private var openPullRequestButton: NSButton!
    private let table = SimpleTable(
        columns: [
            .init(title: "Worktree", width: 170),
            .init(title: "Pull Request", width: 120),
            .init(title: "Decision", width: 110),
            .init(title: "Reason", width: 180),
        ],
        accessibilityLabel: "Dry-run cleanup decisions",
        height: 170
    )

    override func buildContent() {
        addSection("Automatic Cleanup")
        enableCheckbox = UIFactory.checkbox("Automatically remove worktrees whose pull requests are merged", target: self, action: #selector(enableChanged))
        pauseCheckbox = UIFactory.checkbox("Pause automatic cleanup", target: self, action: #selector(pauseChanged))
        delayPopup = UIFactory.popup(CleanupDelay.allCases.map(\.title), target: self, action: #selector(delayChanged))
        delayPopup.setAccessibilityLabel("Cleanup delay after merge")
        stack.addArrangedSubview(enableCheckbox)
        stack.addArrangedSubview(UIFactory.form([("Remove", delayPopup)]))
        stack.addArrangedSubview(pauseCheckbox)
        addFullWidth(consentLabel)
        addFullWidth(buildLabel)
        consentButton = UIFactory.button("", target: self, action: #selector(consentButtonPressed))
        stack.addArrangedSubview(consentButton)

        addSection("Safety Rules")
        addFullWidth(UIFactory.note(SafetyRulesText.summary))

        addSection("Dry Run")
        addFullWidth(UIFactory.note("What WCleaner would do with each linked worktree right now. Nothing is removed from this list. "
            + "Double-click a row for all reasons."))
        addFullWidth(table.scrollView)
        table.onDoubleClick = { [weak self] row in self?.showDetails(for: row.id) }
        table.onSelectionChange = { [weak self] _ in self?.updateOpenPullRequestButton() }
        openPullRequestButton = UIFactory.button("Open Pull Request", target: self, action: #selector(openSelectedPullRequest))
        openPullRequestButton.toolTip = "Opens the selected worktree's pull request on GitHub."
        stack.addArrangedSubview(UIFactory.hStack([
            UIFactory.button("Check Now", target: self, action: #selector(checkNow)),
            openPullRequestButton,
        ]))
    }

    override func refresh() {
        let settings = model.settings
        enableCheckbox.state = settings.autoCleanupEnabled ? .on : .off
        pauseCheckbox.state = settings.autoCleanupPaused ? .on : .off
        pauseCheckbox.isEnabled = settings.autoCleanupEnabled
        delayPopup.isEnabled = settings.hasCleanupConsent
        if let index = CleanupDelay.allCases.firstIndex(of: settings.cleanupDelay) {
            delayPopup.selectItem(at: index)
        }
        if let consent = settings.cleanupConsentAt {
            consentLabel.stringValue = "You allowed WCleaner to remove eligible worktrees on \(EnglishDateFormat.dateTime.format(consent)). "
                + "Pull requests merged before that date need an individual review first."
            consentButton.title = "Withdraw Permission…"
        } else {
            consentLabel.stringValue = "WCleaner has not been allowed to remove worktrees. Until you allow it, every decision is a dry run."
            consentButton.title = "Allow Worktree Removal…"
        }

        buildLabel.isHidden = model.removalEnabledInBuild
        buildLabel.stringValue = "This development build never removes worktrees: every decision is a dry run. "
            + "Set WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1 only when testing with disposable repositories."

        table.setRows(model.snapshot.repositories.flatMap { repository in
            repository.linkedWorktrees.map { worktree in
                SimpleTable.Row(
                    id: worktree.path,
                    cells: [
                        "\(repository.repository.displayName) · \(worktree.branch ?? worktree.name)",
                        Self.pullRequestText(worktree),
                        worktree.decision.title,
                        worktree.decision.summary,
                    ],
                    toolTip: worktree.decision.reasons.map(\.message).joined(separator: "\n"),
                    secondary: [false, false, false, true]
                )
            }
        })
        updateOpenPullRequestButton()
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool {
        change == .settings || change == .snapshot || change == .system
    }

    private static func pullRequestText(_ worktree: WorktreeSnapshot) -> String {
        worktree.pullRequest?.summary ?? "Not checked"
    }

    private func worktree(for path: String?) -> WorktreeSnapshot? {
        guard let path else { return nil }
        return model.snapshot.allLinkedWorktrees.first { $0.path == path }
    }

    private func updateOpenPullRequestButton() {
        openPullRequestButton.isEnabled = worktree(for: table.selectedRow?.id)?.pullRequest?.evidence != nil
    }

    @objc private func openSelectedPullRequest() {
        guard let worktree = worktree(for: table.selectedRow?.id) else { return }
        model.actions?.openPullRequest(worktree)
    }

    private func showDetails(for path: String) {
        guard let worktree = worktree(for: path), let window = view.window else { return }
        var lines = [worktree.path]
        if let evidence = worktree.pullRequest?.evidence {
            lines.append("Pull request #\(evidence.number): \(evidence.title) (\(evidence.state.title))")
        } else {
            lines.append("Pull request: \(Self.pullRequestText(worktree))")
        }
        lines += worktree.decision.reasons.map { "• \($0.message)" }
        let alert = NSAlert()
        alert.messageText = "\(worktree.branch ?? worktree.name): \(worktree.decision.title)"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        let canOpen = worktree.pullRequest?.evidence != nil
        if canOpen { alert.addButton(withTitle: "Open Pull Request") }
        Task { [weak self] in
            let response = await alert.beginSheetModal(for: window)
            if canOpen, response == .alertSecondButtonReturn {
                self?.model.actions?.openPullRequest(worktree)
            }
        }
    }

    @objc private func enableChanged() {
        let wantsOn = enableCheckbox.state == .on
        if wantsOn && !model.settings.hasCleanupConsent {
            enableCheckbox.state = .off
            model.actions?.requestCleanupConsent(enableAutomaticCleanup: true)
            return
        }
        model.settingsStore.update { $0.autoCleanupEnabled = wantsOn }
    }

    @objc private func pauseChanged() {
        model.actions?.setAutomaticCleanupPaused(pauseCheckbox.state == .on)
    }

    @objc private func delayChanged() {
        let delay = CleanupDelay.allCases[delayPopup.indexOfSelectedItem]
        model.settingsStore.update { $0.cleanupDelay = delay }
    }

    @objc private func consentButtonPressed() {
        if model.settings.hasCleanupConsent {
            model.actions?.revokeCleanupConsent()
        } else {
            model.actions?.requestCleanupConsent(enableAutomaticCleanup: false)
        }
    }

    @objc private func checkNow() { model.actions?.checkNow() }
}

/// The user-facing description of WCleaner's cleanup safety rules.
enum SafetyRulesText {
    static let summary = """
    WCleaner removes a linked worktree only when all of these are true, checked again immediately before removal:
    • Its pull request on GitHub is verified as merged (closed-but-unmerged never counts), using the account assigned to the repository.
    • Its HEAD is exactly the pull request's head commit, so no local commits can be lost.
    • It has no staged, unstaged, untracked or ignored files, no submodules, and no merge or rebase in progress.
    • It is not the primary worktree, locked, prunable, detached, symlinked or nested.
    • It was merged after you enrolled the repository and allowed removal, or you reviewed it individually.
    Removal uses only `git worktree remove <path>` without --force. If Git refuses, WCleaner stops and records why. \
    It never deletes branches, runs git clean, or deletes folders itself.
    """
}
