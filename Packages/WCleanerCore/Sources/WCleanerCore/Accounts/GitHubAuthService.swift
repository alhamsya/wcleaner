import Foundation

public enum GitHubAuthError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case accountNotFound
    case needsReconnect(String)
    case differentAccount(expected: String, actual: String)
    case credentialStorage(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "GitHub sign-in is not configured in this build."
        case .accountNotFound:
            "The account is no longer connected."
        case .needsReconnect(let reason):
            "The account needs to be reconnected: \(reason)"
        case .differentAccount(let expected, let actual):
            "You signed in as @\(actual), but this is the reconnect for @\(expected). Nothing was changed. Use Add Account to connect @\(actual)."
        case .credentialStorage(let detail):
            "The token could not be saved to the Keychain: \(detail)"
        case .verificationFailed(let detail):
            "GitHub did not confirm the account: \(detail)"
        }
    }
}

public enum SignInResult: Sendable, Equatable {
    case added(GitHubAccount)
    case updated(GitHubAccount)

    public var account: GitHubAccount {
        switch self {
        case .added(let account), .updated(let account): account
        }
    }
}

/// Connects, verifies, refreshes and disconnects GitHub accounts. Each account is independent:
/// there is no global "signed in" state, and nothing here ever falls back to another account.
public actor GitHubAuthService {
    private let configuration: GitHubConfiguration
    private let deviceFlow: GitHubDeviceFlow
    private let api: GitHubAPIClient
    private let accounts: GitHubAccountStore
    private let credentials: any CredentialStore
    private let now: @Sendable () -> Date
    private var refreshes: [AccountID: Task<String, any Error>] = [:]

    /// Tokens are renewed this long before they expire.
    static let refreshMargin: TimeInterval = 120

    public init(
        configuration: GitHubConfiguration,
        deviceFlow: GitHubDeviceFlow,
        api: GitHubAPIClient,
        accounts: GitHubAccountStore,
        credentials: any CredentialStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.deviceFlow = deviceFlow
        self.api = api
        self.accounts = accounts
        self.credentials = credentials
        self.now = now
    }

    public var isConfigured: Bool { configuration.isConfigured }

    public func beginSignIn() async throws -> DeviceAuthorization {
        guard configuration.isConfigured else { throw GitHubAuthError.notConfigured }
        return try await deviceFlow.start()
    }

    /// Waits for the user to authorize, verifies the identity with `GET /user`, then stores the token.
    /// When `expecting` is set (Reconnect), a different GitHub user is rejected and nothing is stored.
    public func completeSignIn(_ authorization: DeviceAuthorization, expecting: AccountID? = nil) async throws -> SignInResult {
        let token = try await deviceFlow.poll(authorization)
        return try await register(token: token, expecting: expecting)
    }

    /// Verifies and stores a freshly issued token. Split out for testing.
    func register(token: OAuthToken, expecting: AccountID?) async throws -> SignInResult {
        let user: GitHubUserDTO
        do {
            user = try await api.currentUser(token: token.accessToken)
        } catch {
            throw GitHubAuthError.verificationFailed(error.userMessage)
        }
        let id = AccountID(host: configuration.host, userID: user.id)

        if let expecting, expecting != id {
            let expectedLogin = await accounts.account(expecting)?.login ?? String(expecting.userID)
            throw GitHubAuthError.differentAccount(expected: expectedLogin, actual: user.login)
        }

        let existing = await accounts.account(id)
        do {
            try credentials.save(StoredCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken), for: id)
        } catch {
            throw GitHubAuthError.credentialStorage(error.userMessage)
        }

        let timestamp = now()
        let account = GitHubAccount(
            id: id,
            login: user.login,
            name: user.name,
            addedAt: existing?.addedAt ?? timestamp,
            lastVerifiedAt: timestamp,
            accessTokenExpiresAt: token.expiresAt,
            refreshTokenExpiresAt: token.refreshTokenExpiresAt,
            hasRefreshToken: token.refreshToken != nil,
            state: .connected
        )
        try await accounts.upsert(account)
        await api.clearCache(for: id)
        return existing == nil ? .added(account) : .updated(account)
    }

    /// Removes one account's tokens and metadata. Other accounts are untouched.
    public func disconnect(_ id: AccountID) async throws {
        refreshes[id]?.cancel()
        refreshes[id] = nil
        try credentials.delete(for: id)
        try await accounts.remove(id)
        await api.clearCache(for: id)
    }

    /// A usable access token for exactly this account, renewing it if it is about to expire.
    public func accessToken(for id: AccountID) async throws -> String {
        guard let account = await accounts.account(id) else { throw GitHubAuthError.accountNotFound }
        if case .needsReconnect(let reason) = account.state {
            throw GitHubAuthError.needsReconnect(reason)
        }
        let stored: StoredCredentials?
        do {
            stored = try credentials.load(for: id)
        } catch {
            throw GitHubAuthError.credentialStorage(error.userMessage)
        }
        guard let stored else {
            try await markNeedsReconnect(id, reason: "Its token is missing from the Keychain.")
            throw GitHubAuthError.needsReconnect("Its token is missing from the Keychain.")
        }

        guard let expiresAt = account.accessTokenExpiresAt, now() >= expiresAt.addingTimeInterval(-Self.refreshMargin) else {
            return stored.accessToken
        }
        return try await refresh(id, account: account, stored: stored)
    }

    /// Called when GitHub answers 401 for this account's token.
    public func handleUnauthorized(_ id: AccountID) async {
        try? await markNeedsReconnect(id, reason: "GitHub rejected its token.")
    }

    public func markNeedsReconnect(_ id: AccountID, reason: String) async throws {
        try await accounts.update(id) { $0.state = .needsReconnect(reason: reason) }
    }

    private func refresh(_ id: AccountID, account: GitHubAccount, stored: StoredCredentials) async throws -> String {
        if let inFlight = refreshes[id] {
            return try await inFlight.value
        }
        guard let refreshToken = stored.refreshToken,
              account.refreshTokenExpiresAt.map({ now() < $0 }) ?? true else {
            try await markNeedsReconnect(id, reason: "Its token expired.")
            throw GitHubAuthError.needsReconnect("Its token expired.")
        }
        let deviceFlow = self.deviceFlow
        let task = Task { try await deviceFlow.refresh(refreshToken: refreshToken) }
        let wrapped = Task<String, any Error> {
            let token = try await task.value
            return token.accessToken
        }
        refreshes[id] = wrapped
        defer { refreshes[id] = nil }

        let token: OAuthToken
        do {
            token = try await task.value
        } catch {
            try? await markNeedsReconnect(id, reason: "Its token expired and could not be renewed.")
            throw GitHubAuthError.needsReconnect("Its token expired and could not be renewed.")
        }
        do {
            try credentials.save(StoredCredentials(accessToken: token.accessToken, refreshToken: token.refreshToken ?? refreshToken), for: id)
        } catch {
            throw GitHubAuthError.credentialStorage(error.userMessage)
        }
        try await accounts.update(id) {
            $0.accessTokenExpiresAt = token.expiresAt
            if let refreshExpiry = token.refreshTokenExpiresAt { $0.refreshTokenExpiresAt = refreshExpiry }
            $0.hasRefreshToken = true
            $0.state = .connected
        }
        return token.accessToken
    }
}
