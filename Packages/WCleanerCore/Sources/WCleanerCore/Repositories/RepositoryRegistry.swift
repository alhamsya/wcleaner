import Foundation

public enum RepositoryRegistryError: Error, Sendable, Equatable, LocalizedError {
    case pathDoesNotExist(String)
    case notADirectory(String)
    case notAGitRepository(String)
    case alreadyRegistered(String)
    case gitFailure(String)

    public var errorDescription: String? {
        switch self {
        case .pathDoesNotExist(let path): "The folder does not exist: \(path)"
        case .notADirectory(let path): "Not a folder: \(path)"
        case .notAGitRepository(let path): "This folder is not inside a Git repository: \(path)"
        case .alreadyRegistered(let name): "\(name) is already being monitored."
        case .gitFailure(let detail): "Git could not read the repository: \(detail)"
        }
    }
}

/// The user's explicit list of monitored repositories, persisted as non-secret JSON.
public actor RepositoryRegistry {
    private let store: JSONFileStore<[RegisteredRepository]>
    private let git: GitClient
    private var repositories: [RegisteredRepository]

    public init(store: JSONFileStore<[RegisteredRepository]>, git: GitClient) {
        self.store = store
        self.git = git
        self.repositories = (try? store.load()) ?? []
    }

    public func all() -> [RegisteredRepository] {
        repositories
    }

    public func repository(_ id: UUID) -> RegisteredRepository? {
        repositories.first { $0.id == id }
    }

    /// Validates and registers the repository containing `path`. If `path` is a linked worktree,
    /// the repository's primary worktree is registered instead.
    @discardableResult
    public func add(path: String, now: Date = Date()) async throws -> RegisteredRepository {
        guard let canonical = PathCanonicalizer.realPath(PathCanonicalizer.standardize(path)) else {
            throw RepositoryRegistryError.pathDoesNotExist(path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RepositoryRegistryError.notADirectory(canonical)
        }

        let location: GitClient.RepositoryLocation
        do {
            location = try await git.repositoryLocation(at: canonical)
        } catch {
            throw RepositoryRegistryError.notAGitRepository(canonical)
        }
        guard let commonDirectory = PathCanonicalizer.realPath(location.commonDirectory) else {
            throw RepositoryRegistryError.notAGitRepository(canonical)
        }

        let primaryPath: String
        do {
            let records = try await git.worktreeList(repositoryPath: canonical)
            guard let first = records.first, let resolved = PathCanonicalizer.realPath(first.path) else {
                throw RepositoryRegistryError.gitFailure("Git did not list a primary worktree.")
            }
            primaryPath = resolved
        } catch let error as RepositoryRegistryError {
            throw error
        } catch {
            throw RepositoryRegistryError.gitFailure(String(describing: error))
        }

        var name = (primaryPath as NSString).lastPathComponent
        if location.isBare && name.hasSuffix(".git") && name.count > 4 {
            name = String(name.dropLast(4))
        }

        // Re-check after the awaits above: another add may have completed in the meantime.
        if let existing = repositories.first(where: { $0.commonDirectory == commonDirectory }) {
            throw RepositoryRegistryError.alreadyRegistered(existing.displayName)
        }
        let repository = RegisteredRepository(
            displayName: name,
            path: primaryPath,
            commonDirectory: commonDirectory,
            isBare: location.isBare,
            addedAt: now
        )
        repositories.append(repository)
        repositories.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        try persist()
        return repository
    }

    public func remove(id: UUID) throws {
        repositories.removeAll { $0.id == id }
        try persist()
    }

    public func update(id: UUID, _ mutate: @Sendable (inout RegisteredRepository) -> Void) throws {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        mutate(&repositories[index])
        try persist()
    }

    private func persist() throws {
        try store.save(repositories)
    }
}

/// Lists worktrees for a registered repository after confirming the repository is still the same one.
public struct WorktreeScanner: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public enum ScanError: Error, Sendable, Equatable, LocalizedError {
        case repositoryMissing(String)
        case repositoryChanged(String)
        case git(String)

        public var errorDescription: String? {
            switch self {
            case .repositoryMissing(let path): "The repository folder is missing: \(path)"
            case .repositoryChanged(let path): "The folder at \(path) is no longer the repository that was added. Remove and add it again."
            case .git(let detail): detail
            }
        }
    }

    public func scan(_ repository: RegisteredRepository) async throws -> [WorktreeRecord] {
        guard FileManager.default.fileExists(atPath: repository.path) else {
            throw ScanError.repositoryMissing(repository.path)
        }
        do {
            let location = try await git.repositoryLocation(at: repository.path)
            guard PathCanonicalizer.realPath(location.commonDirectory) == repository.commonDirectory else {
                throw ScanError.repositoryChanged(repository.path)
            }
            return try await git.worktreeList(repositoryPath: repository.path)
        } catch let error as ScanError {
            throw error
        } catch {
            throw ScanError.git(String(describing: error))
        }
    }
}
