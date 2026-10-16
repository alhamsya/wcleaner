import Foundation

/// Which account WCleaner uses for a repository, or why it cannot use one.
public enum AccountResolution: Sendable, Equatable {
    /// `automatic` is true when assigned because exactly one connected account could read the repository.
    case assigned(AccountID, automatic: Bool)
    /// Several connected accounts can read the repository; the user must choose.
    case needsSelection([AccountID])
    /// No connected account can read the repository (or none are connected).
    case needsAccount
    /// The mapped account was disconnected, expired, or lost access. WCleaner never falls back to another account.
    case accountUnavailable(AccountID, reason: String)
    /// The repository has no usable GitHub remote.
    case notGitHub(String)
    /// Verification could not complete (network error, rate limit). Temporary; blocks cleanup.
    case unverified(String)

    public var assignedAccount: AccountID? {
        if case .assigned(let account, _) = self { return account }
        return nil
    }

    public var title: String {
        switch self {
        case .assigned(_, let automatic): automatic ? "Assigned automatically" : "Assigned"
        case .needsSelection: "Choose Account"
        case .needsAccount: "Needs Account"
        case .accountUnavailable: "Account Unavailable"
        case .notGitHub: "Not a GitHub Repository"
        case .unverified: "Not Verified"
        }
    }
}
