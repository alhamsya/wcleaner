import Foundation

/// Immutable identity of a hosting account: host plus numeric user ID (never the mutable login).
public struct AccountID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let host: String
    public let userID: Int64

    public init(host: String, userID: Int64) {
        self.host = host.lowercased()
        self.userID = userID
    }

    public var storageKey: String { "\(host):\(userID)" }
    public var description: String { storageKey }

    public static func < (lhs: AccountID, rhs: AccountID) -> Bool {
        (lhs.host, lhs.userID) < (rhs.host, rhs.userID)
    }
}

public enum AccountConnectionState: Codable, Sendable, Hashable {
    case connected
    case needsReconnect(reason: String)

    public var isConnected: Bool { self == .connected }
}

/// Non-secret account metadata. Tokens live only in the Keychain.
public struct GitHubAccount: Codable, Sendable, Identifiable, Hashable {
    public var id: AccountID
    public var login: String
    public var name: String?
    public var addedAt: Date
    public var lastVerifiedAt: Date
    public var accessTokenExpiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var hasRefreshToken: Bool
    public var state: AccountConnectionState

    public init(
        id: AccountID,
        login: String,
        name: String? = nil,
        addedAt: Date = Date(),
        lastVerifiedAt: Date = Date(),
        accessTokenExpiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        hasRefreshToken: Bool = false,
        state: AccountConnectionState = .connected
    ) {
        self.id = id
        self.login = login
        self.name = name
        self.addedAt = addedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.hasRefreshToken = hasRefreshToken
        self.state = state
    }

    public var displayName: String {
        if let name, !name.isEmpty { return "\(name) (@\(login))" }
        return "@\(login)"
    }
}

/// A GitHub repository resolved through the API: numeric ID is the canonical identity.
public struct ResolvedGitHubRepository: Codable, Sendable, Hashable {
    public var id: Int64
    public var host: String
    public var owner: String
    public var name: String
    public var htmlURL: String
    public var isPrivate: Bool
    public var isFork: Bool
    public var parentFullName: String?

    public init(
        id: Int64,
        host: String = "github.com",
        owner: String,
        name: String,
        htmlURL: String,
        isPrivate: Bool = false,
        isFork: Bool = false,
        parentFullName: String? = nil
    ) {
        self.id = id
        self.host = host
        self.owner = owner
        self.name = name
        self.htmlURL = htmlURL
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.parentFullName = parentFullName
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var ref: HostedRepositoryRef { HostedRepositoryRef(host: host, owner: owner, name: name) }
}

public enum PullRequestState: String, Codable, Sendable, Hashable {
    case open
    case merged
    case closedUnmerged
    case unknown

    public var title: String {
        switch self {
        case .open: "Open"
        case .merged: "Merged"
        case .closedUnmerged: "Closed Unmerged"
        case .unknown: "Unknown"
        }
    }

    /// Only a closed pull request with a non-nil `merged_at` counts as merged.
    public static func from(apiState: String, mergedAt: Date?) -> PullRequestState {
        switch apiState {
        case "open": .open
        case "closed": mergedAt != nil ? .merged : .closedUnmerged
        default: .unknown
        }
    }
}

/// Facts about one pull request, as returned by GitHub for a specific account.
public struct PullRequestEvidence: Codable, Sendable, Hashable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PullRequestState
    public var mergedAt: Date?
    public var headSHA: String
    public var headRef: String
    public var headRepositoryID: Int64?
    public var headRepositoryFullName: String?
    public var baseRepositoryID: Int64
    public var baseRef: String
    public var accountID: AccountID
    public var fetchedAt: Date
    /// False when the head repository could not be confirmed (e.g. the fork was deleted).
    public var headRepositoryVerified: Bool

    public init(
        number: Int,
        title: String,
        url: String,
        state: PullRequestState,
        mergedAt: Date?,
        headSHA: String,
        headRef: String,
        headRepositoryID: Int64?,
        headRepositoryFullName: String?,
        baseRepositoryID: Int64,
        baseRef: String,
        accountID: AccountID,
        fetchedAt: Date,
        headRepositoryVerified: Bool
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.mergedAt = mergedAt
        self.headSHA = headSHA
        self.headRef = headRef
        self.headRepositoryID = headRepositoryID
        self.headRepositoryFullName = headRepositoryFullName
        self.baseRepositoryID = baseRepositoryID
        self.baseRef = baseRef
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.headRepositoryVerified = headRepositoryVerified
    }
}

/// Outcome of associating a worktree with a pull request.
public enum PullRequestMatch: Sendable, Equatable {
    /// Exactly one pull request whose head SHA equals the worktree HEAD.
    case matched(PullRequestEvidence)
    /// A pull request exists for the branch but its head differs from the local HEAD.
    case headMismatch(PullRequestEvidence, localHead: String)
    /// More than one pull request could match; manual review required.
    case ambiguous([Int])
    case notFound
    /// The lookup failed (network, rate limit, permissions). Never treated as "not merged" or "merged".
    case unavailable(String)

    public var evidence: PullRequestEvidence? {
        switch self {
        case .matched(let evidence), .headMismatch(let evidence, _): evidence
        default: nil
        }
    }
}
