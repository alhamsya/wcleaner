import AppKit
import WCleanerCore

@MainActor
final class RepositoriesPaneController: SettingsPaneViewController {
    private let table = SimpleTable(
        columns: [
            .init(title: "Repository", width: 210),
            .init(title: "GitHub", width: 150),
            .init(title: "Account", width: 140),
            .init(title: "Worktrees", width: 70),
        ],
        accessibilityLabel: "Monitored repositories",
        height: 190
    )
    private var removeButton: NSButton!
    private var accountPopup: NSPopUpButton!
    private let detailLabel = UIFactory.note("")
    private let totalsLabel = UIFactory.label("")

    override func buildContent() {
        addSection("Monitored Repositories")
        addFullWidth(UIFactory.note(
            "Add the local Git repositories WCleaner should watch. Signing in to GitHub cannot discover local folders, "
                + "and WCleaner only ever considers worktrees that Git lists for a repository you added here."
        ))
        addFullWidth(table.scrollView)
        table.onSelectionChange = { [weak self] _ in self?.updateSelection() }

        let addButton = UIFactory.button("Add Repository…", target: self, action: #selector(addRepository))
        removeButton = UIFactory.button("Remove", target: self, action: #selector(removeRepository))
        accountPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        accountPopup.target = self
        accountPopup.setAccessibilityLabel("Choose GitHub account for the selected repository")
        stack.addArrangedSubview(UIFactory.hStack([addButton, removeButton, accountPopup]))
        addFullWidth(detailLabel)

        addSection("Disk Usage")
        stack.addArrangedSubview(totalsLabel)
        stack.addArrangedSubview(UIFactory.button("Refresh Sizes", target: self, action: #selector(refreshSizes)))
        addFullWidth(UIFactory.note(
            "Sizes are estimates measured with du, including ignored and build files. Because APFS shares cloned and "
                + "duplicated blocks, the space actually freed by removing a worktree may be smaller. Sizes are cached for about an hour."
        ))
    }

    override func refresh() {
        table.setRows(model.repositories.map { repository in
            let snapshot = model.repositorySnapshot(repository.id)
            let github = snapshot?.githubRepository?.fullName ?? "—"
            let account = accountText(snapshot)
            let worktrees = snapshot.map { String($0.linkedWorktrees.count) } ?? "—"
            return SimpleTable.Row(
                id: repository.id.uuidString,
                cells: ["\(repository.displayName) — \(repository.path.abbreviatedPath)", github, account, worktrees],
                toolTip: repository.path,
                secondary: [false, true, false, true]
            )
        })
        let snapshot = model.snapshot
        totalsLabel.stringValue = "Estimated worktree usage: \(snapshot.totalUsage.displayString) · "
            + "Estimated cleanup opportunity: \(snapshot.cleanupOpportunity.displayString)"
        updateSelection()
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool {
        change == .repositories || change == .snapshot || change == .accounts
    }

    private func accountText(_ snapshot: RepositorySnapshot?) -> String {
        guard let snapshot else { return "Not checked" }
        switch snapshot.accountResolution {
        case .assigned(let id, _):
            return model.account(id).map { "@\($0.login)" } ?? "Unknown account"
        default:
            return snapshot.accountResolution.title
        }
    }

    private var selectedRepository: RegisteredRepository? {
        guard let row = table.selectedRow else { return nil }
        return model.repositories.first { $0.id.uuidString == row.id }
    }

    private func updateSelection() {
        guard let repository = selectedRepository else {
            removeButton.isEnabled = false
            accountPopup.isEnabled = false
            rebuildAccountMenu(title: "Choose Account", accounts: [], current: nil)
            detailLabel.stringValue = model.repositories.isEmpty ? "No repositories yet." : "Select a repository to see details."
            return
        }
        removeButton.isEnabled = true
        let snapshot = model.repositorySnapshot(repository.id)
        let connected = model.accounts.filter { $0.state.isConnected }
        accountPopup.isEnabled = !connected.isEmpty
        rebuildAccountMenu(title: "Choose Account", accounts: connected, current: snapshot?.accountResolution.assignedAccount)

        var lines = ["Path: \(repository.path)"]
        if let github = snapshot?.githubRepository {
            lines.append("GitHub: \(github.fullName) (repository ID \(github.id))")
        }
        if let resolution = snapshot?.accountResolution {
            lines.append("Account: \(Self.describe(resolution, model: model))")
        }
        lines.append("Enrolled: \(EnglishDateFormat.dateTime.format(repository.addedAt))")
        if let error = snapshot?.error {
            lines.append("Problem: \(error)")
        }
        detailLabel.stringValue = lines.joined(separator: "\n")
    }

    static func describe(_ resolution: AccountResolution, model: AppModel) -> String {
        func login(_ id: AccountID) -> String { model.account(id).map { "@\($0.login)" } ?? "account \(id.userID)" }
        switch resolution {
        case .assigned(let id, let automatic):
            return automatic ? "\(login(id)) (the only connected account with access)" : "\(login(id)) (chosen by you)"
        case .needsSelection(let ids):
            return "Several accounts can read this repository (\(ids.map(login).joined(separator: ", "))). Choose one."
        case .needsAccount:
            return "No connected account can read this repository. Add an account with access."
        case .accountUnavailable(let id, let reason):
            return "\(login(id)) is unavailable (\(reason)). Reconnect it or choose another account explicitly."
        case .notGitHub(let detail):
            return "Not a GitHub repository: \(detail)"
        case .unverified(let detail):
            return "Not verified yet: \(detail)"
        }
    }

    private func rebuildAccountMenu(title: String, accounts: [GitHubAccount], current: AccountID?) {
        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        for account in accounts {
            let item = NSMenuItem(title: account.displayName, action: #selector(accountChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.id.storageKey
            item.state = account.id == current ? .on : .off
            menu.addItem(item)
        }
        accountPopup.menu = menu
    }

    @objc private func accountChosen(_ sender: NSMenuItem) {
        guard let repository = selectedRepository,
              let key = sender.representedObject as? String,
              let account = model.accounts.first(where: { $0.id.storageKey == key }) else { return }
        model.actions?.assignAccount(account.id, to: repository.id)
    }

    @objc private func addRepository() { model.actions?.addRepository() }

    @objc private func removeRepository() {
        guard let repository = selectedRepository else { return }
        model.actions?.removeRepository(repository.id)
    }

    @objc private func refreshSizes() { model.actions?.refreshDiskUsage() }
}
