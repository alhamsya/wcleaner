import AppKit
import WCleanerCore

@MainActor
final class AccountsPaneController: SettingsPaneViewController {
    private let configurationLabel = UIFactory.note("")
    private let table = SimpleTable(
        columns: [
            .init(title: "Account", width: 230),
            .init(title: "Status", width: 170),
            .init(title: "Token", width: 160),
        ],
        accessibilityLabel: "Connected GitHub accounts",
        height: 170
    )
    private var addButton: NSButton!
    private var reconnectButton: NSButton!
    private var disconnectButton: NSButton!

    override func buildContent() {
        addSection("GitHub.com Accounts")
        addFullWidth(configurationLabel)
        addFullWidth(table.scrollView)
        table.onSelectionChange = { [weak self] _ in self?.updateButtons() }

        addButton = UIFactory.button("Add Account…", target: self, action: #selector(addAccount))
        reconnectButton = UIFactory.button("Reconnect…", target: self, action: #selector(reconnect))
        disconnectButton = UIFactory.button("Disconnect…", target: self, action: #selector(disconnect))
        stack.addArrangedSubview(UIFactory.hStack([addButton, reconnectButton, disconnectButton]))

        addFullWidth(UIFactory.note(
            "You can connect several GitHub.com accounts at once. Signing in uses GitHub's device flow in your browser; "
                + "WCleaner never sees your password. Each account's token is stored in its own macOS Keychain item and is "
                + "used only to read repository and pull request information from api.github.com. "
                + "Disconnecting an account removes its token from this Mac and does not affect other accounts; "
                + "you can also revoke access on GitHub under Settings › Applications."
        ))
        addFullWidth(UIFactory.note("Only GitHub.com is supported in this version."))
    }

    override func refresh() {
        if model.gitHubClientConfigured {
            configurationLabel.stringValue = "Sign in with GitHub is available."
            configurationLabel.textColor = .secondaryLabelColor
        } else {
            configurationLabel.stringValue = "GitHub sign-in is not configured in this build: no GitHub App client ID was provided. "
                + "Set WCLEANER_GITHUB_CLIENT_ID as described in GITHUB_APP_SETUP.md and rebuild. No account can be connected until then."
            configurationLabel.textColor = .systemOrange
        }

        table.setRows(model.accounts.map { account in
            let status: String
            switch account.state {
            case .connected: status = "Connected"
            case .needsReconnect(let reason): status = "Needs Reconnect: \(reason)"
            }
            let token: String
            if let expires = account.accessTokenExpiresAt {
                token = (account.hasRefreshToken ? "Renews · " : "Expires ") + EnglishDateFormat.dateTime.format(expires)
            } else {
                token = "Does not expire"
            }
            return SimpleTable.Row(
                id: account.id.storageKey,
                cells: [account.displayName, status, token],
                toolTip: "\(account.displayName) — GitHub user ID \(account.id.userID)",
                secondary: [false, false, true]
            )
        })
        updateButtons()
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool {
        change == .accounts || change == .system
    }

    private var selectedAccount: GitHubAccount? {
        guard let row = table.selectedRow else { return nil }
        return model.accounts.first { $0.id.storageKey == row.id }
    }

    private func updateButtons() {
        addButton.isEnabled = model.gitHubClientConfigured
        reconnectButton.isEnabled = model.gitHubClientConfigured && selectedAccount != nil
        disconnectButton.isEnabled = selectedAccount != nil
    }

    @objc private func addAccount() { model.actions?.addAccount() }

    @objc private func reconnect() {
        guard let account = selectedAccount else { return }
        model.actions?.reconnectAccount(account.id)
    }

    @objc private func disconnect() {
        guard let account = selectedAccount else { return }
        model.actions?.disconnectAccount(account.id)
    }
}
