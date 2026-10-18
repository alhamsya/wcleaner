import Foundation

public enum CleanupMode: String, Codable, Sendable {
    case automatic
    case manual
    /// Manual removal the user asked for although the pull request is not merged. Every local check
    /// still applies; the branch and its commits are kept.
    case manualUnmerged
    /// Like `manualUnmerged`, after saving the worktree's uncommitted changes in a Git stash.
    case manualStashed
}

public enum CleanupResult: String, Codable, Sendable {
    /// `git worktree remove` succeeded and the directory is gone.
    case removed
    /// A safety re-check failed immediately before removal; nothing was touched.
    case refused
    /// Git refused or failed. WCleaner never retries with force.
    case failed
    /// The user approved a worktree after review (no removal happened).
    case reviewed
}

/// One local, non-secret audit log entry. Never contains tokens or credentials.
public struct CleanupHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var mode: CleanupMode
    public var result: CleanupResult
    public var repositoryName: String
    public var repositoryPath: String
    public var githubRepository: String?
    public var worktreePath: String
    public var branch: String?
    public var headSHA: String?
    public var pullRequestNumber: Int?
    public var pullRequestURL: String?
    public var accountLogin: String?
    public var accountID: String?
    /// Why the worktree was considered eligible (or why the attempt stopped).
    public var rationale: [String]
    public var errorMessage: String?
    public var estimatedSizeBytes: Int64?
    /// The stash commit holding the worktree's uncommitted changes, when WCleaner saved them first.
    public var stashCommit: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        mode: CleanupMode,
        result: CleanupResult,
        repositoryName: String,
        repositoryPath: String,
        githubRepository: String?,
        worktreePath: String,
        branch: String?,
        headSHA: String?,
        pullRequestNumber: Int?,
        pullRequestURL: String?,
        accountLogin: String?,
        accountID: String?,
        rationale: [String],
        errorMessage: String?,
        estimatedSizeBytes: Int64?,
        stashCommit: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.result = result
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.githubRepository = githubRepository
        self.worktreePath = worktreePath
        self.branch = branch
        self.headSHA = headSHA
        self.pullRequestNumber = pullRequestNumber
        self.pullRequestURL = pullRequestURL
        self.accountLogin = accountLogin
        self.accountID = accountID
        self.rationale = rationale
        self.errorMessage = errorMessage
        self.estimatedSizeBytes = estimatedSizeBytes
        self.stashCommit = stashCommit
    }
}

/// Append-only JSON Lines audit log in Application Support, trimmed to `maxEntries`.
public actor CleanupHistoryStore {
    public let fileURL: URL
    private let directory: AppDataDirectory
    private let maxEntries: Int
    private var cache: [CleanupHistoryEntry]?

    public init(directory: AppDataDirectory, fileName: String = "cleanup-history.jsonl", maxEntries: Int = 2000) {
        self.directory = directory
        self.fileURL = directory.file(fileName)
        self.maxEntries = maxEntries
    }

    /// Newest first.
    public func entries() -> [CleanupHistoryEntry] {
        loadIfNeeded().reversed()
    }

    public func append(_ entry: CleanupHistoryEntry) throws {
        var all = loadIfNeeded()
        all.append(entry)
        let trimmed = all.count > maxEntries
        if trimmed {
            all.removeFirst(all.count - maxEntries)
        }
        cache = all
        try directory.ensureExists()
        if trimmed || !FileManager.default.fileExists(atPath: fileURL.path) {
            try rewrite(all)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Self.encodeLine(entry))
        }
    }

    public func clear() throws {
        cache = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func loadIfNeeded() -> [CleanupHistoryEntry] {
        if let cache { return cache }
        var loaded: [CleanupHistoryEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = WCJSON.decoder()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                // Skip corrupt lines instead of losing the whole log.
                if let entry = try? decoder.decode(CleanupHistoryEntry.self, from: Data(line)) {
                    loaded.append(entry)
                }
            }
        }
        cache = loaded
        return loaded
    }

    private func rewrite(_ entries: [CleanupHistoryEntry]) throws {
        var data = Data()
        for entry in entries {
            data.append(try Self.encodeLine(entry))
        }
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func encodeLine(_ entry: CleanupHistoryEntry) throws -> Data {
        var data = try WCJSON.encoder().encode(entry)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
