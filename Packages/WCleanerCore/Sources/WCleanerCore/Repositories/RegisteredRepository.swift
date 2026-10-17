import Foundation

/// A local repository the user explicitly added. WCleaner never discovers repositories on its own.
public struct RegisteredRepository: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// Canonical path of the primary worktree (or the bare repository directory).
    public var path: String
    /// Canonical Git common directory. Two registrations with the same common directory are the same repository.
    public var commonDirectory: String
    public var isBare: Bool
    /// Enrollment time. Pull requests merged before this are never cleaned automatically without review.
    public var addedAt: Date
    /// Optional override of the remote used to look up pull requests (default: `upstream`, then `origin`).
    public var pullRequestRemote: String?
    /// Ignored files and folders (relative to the worktree root, normalized by `DisposablePaths`) that the user
    /// accepts losing when a worktree of this repository is removed, for example `node_modules`.
    /// Every other ignored file still blocks removal.
    public var disposableIgnoredPaths: [String]

    public init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        commonDirectory: String,
        isBare: Bool = false,
        addedAt: Date = Date(),
        pullRequestRemote: String? = nil,
        disposableIgnoredPaths: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.commonDirectory = commonDirectory
        self.isBare = isBare
        self.addedAt = addedAt
        self.pullRequestRemote = pullRequestRemote
        self.disposableIgnoredPaths = disposableIgnoredPaths
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, path, commonDirectory, isBare, addedAt, pullRequestRemote, disposableIgnoredPaths
    }

    /// Repositories saved before `disposableIgnoredPaths` existed have none. Entries that are not valid
    /// relative paths are dropped rather than trusted.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        path = try container.decode(String.self, forKey: .path)
        commonDirectory = try container.decode(String.self, forKey: .commonDirectory)
        isBare = try container.decode(Bool.self, forKey: .isBare)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        pullRequestRemote = try container.decodeIfPresent(String.self, forKey: .pullRequestRemote)
        let stored = try container.decodeIfPresent([String].self, forKey: .disposableIgnoredPaths) ?? []
        disposableIgnoredPaths = DisposablePaths.normalizedList(stored)
    }
}
