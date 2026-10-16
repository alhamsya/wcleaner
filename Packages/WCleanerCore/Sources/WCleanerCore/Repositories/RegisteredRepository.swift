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

    public init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        commonDirectory: String,
        isBare: Bool = false,
        addedAt: Date = Date(),
        pullRequestRemote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.commonDirectory = commonDirectory
        self.isBare = isBare
        self.addedAt = addedAt
        self.pullRequestRemote = pullRequestRemote
    }
}
