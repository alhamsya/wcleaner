import Foundation
import Security

/// An account's secrets. Descriptions are redacted so they can never be logged by accident.
public struct StoredCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String?

    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public var description: String {
        "StoredCredentials(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "none" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}

public protocol CredentialStore: Sendable {
    func save(_ credentials: StoredCredentials, for account: AccountID) throws
    func load(for account: AccountID) throws -> StoredCredentials?
    func delete(for account: AccountID) throws
}

public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    case status(OSStatus, String)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .status(let status, let message): "Keychain error \(status): \(message)"
        case .invalidData: "The Keychain item could not be read."
        }
    }

    static func from(_ status: OSStatus) -> KeychainError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "Unknown error"
        return .status(status, message)
    }
}

/// Stores each account's access token and refresh token as separate generic-password items in the
/// user's login Keychain, keyed by `host:userID`. Items are device-only and never synchronized.
public struct KeychainCredentialStore: CredentialStore {
    public let accessService: String
    public let refreshService: String

    public init(serviceBase: String = "io.github.alhamsya.WCleaner.github") {
        self.accessService = serviceBase + ".access-token"
        self.refreshService = serviceBase + ".refresh-token"
    }

    public func save(_ credentials: StoredCredentials, for account: AccountID) throws {
        try upsert(service: accessService, account: account, secret: credentials.accessToken, label: "WCleaner GitHub access token")
        if let refresh = credentials.refreshToken {
            try upsert(service: refreshService, account: account, secret: refresh, label: "WCleaner GitHub refresh token")
        } else {
            try deleteItem(service: refreshService, account: account)
        }
    }

    public func load(for account: AccountID) throws -> StoredCredentials? {
        guard let access = try read(service: accessService, account: account) else { return nil }
        let refresh = try read(service: refreshService, account: account)
        return StoredCredentials(accessToken: access, refreshToken: refresh)
    }

    public func delete(for account: AccountID) throws {
        try deleteItem(service: accessService, account: account)
        try deleteItem(service: refreshService, account: account)
    }

    private func baseQuery(service: String, account: AccountID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.storageKey,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    private func upsert(service: String, account: AccountID, secret: String, label: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(service: service, account: account)
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.from(status) }

        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel] = "\(label) (\(account.storageKey))"
        add[kSecAttrDescription] = "Used by WCleaner to read pull requests on \(account.host)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.from(addStatus) }
    }

    private func read(service: String, account: AccountID) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.from(status) }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return string
    }

    private func deleteItem(service: String, account: AccountID) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.from(status) }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AccountID: StoredCredentials] = [:]
    public var failSaves = false

    public init() {}

    public func save(_ credentials: StoredCredentials, for account: AccountID) throws {
        try lock.withLock {
            if failSaves { throw KeychainError.status(-25_293, "Simulated failure") }
            items[account] = credentials
        }
    }

    public func load(for account: AccountID) throws -> StoredCredentials? {
        lock.withLock { items[account] }
    }

    public func delete(for account: AccountID) throws {
        lock.withLock { items[account] = nil }
    }

    public var storedAccounts: [AccountID] {
        lock.withLock { Array(items.keys).sorted() }
    }
}
