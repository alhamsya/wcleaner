import Foundation

/// Non-secret account metadata, persisted as JSON. Accounts are unique by `AccountID` (host + numeric user ID).
public actor GitHubAccountStore {
    private let store: JSONFileStore<[GitHubAccount]>
    private var accounts: [GitHubAccount]

    public init(store: JSONFileStore<[GitHubAccount]>) {
        self.store = store
        self.accounts = (try? store.load()) ?? []
    }

    public func all() -> [GitHubAccount] {
        accounts
    }

    public func account(_ id: AccountID) -> GitHubAccount? {
        accounts.first { $0.id == id }
    }

    /// Inserts or replaces by ID, so signing in twice to the same GitHub user never creates a duplicate.
    public func upsert(_ account: GitHubAccount) throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            var merged = account
            merged.addedAt = accounts[index].addedAt
            accounts[index] = merged
        } else {
            accounts.append(account)
        }
        accounts.sort { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        try store.save(accounts)
    }

    public func update(_ id: AccountID, _ mutate: @Sendable (inout GitHubAccount) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&accounts[index])
        try store.save(accounts)
    }

    public func remove(_ id: AccountID) throws {
        accounts.removeAll { $0.id == id }
        try store.save(accounts)
    }
}
