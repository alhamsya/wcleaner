import Foundation

/// The persisted link between a local repository and the GitHub account used for it.
public struct RepositoryAccountMapping: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Exactly one connected account could read the repository when it was first checked.
        case automatic
        /// The user chose the account.
        case explicit
    }

    public var repositoryID: UUID
    public var accountID: AccountID
    public var githubRepositoryID: Int64
    public var githubFullName: String
    public var source: Source
    public var assignedAt: Date

    public init(repositoryID: UUID, accountID: AccountID, githubRepositoryID: Int64, githubFullName: String, source: Source, assignedAt: Date) {
        self.repositoryID = repositoryID
        self.accountID = accountID
        self.githubRepositoryID = githubRepositoryID
        self.githubFullName = githubFullName
        self.source = source
        self.assignedAt = assignedAt
    }
}

public actor RepositoryAccountMappingStore {
    private let store: JSONFileStore<[RepositoryAccountMapping]>
    private var mappings: [UUID: RepositoryAccountMapping]

    public init(store: JSONFileStore<[RepositoryAccountMapping]>) {
        self.store = store
        let loaded = (try? store.load()) ?? []
        self.mappings = Dictionary(loaded.map { ($0.repositoryID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func mapping(for repository: UUID) -> RepositoryAccountMapping? {
        mappings[repository]
    }

    public func all() -> [RepositoryAccountMapping] {
        Array(mappings.values)
    }

    public func set(_ mapping: RepositoryAccountMapping) throws {
        mappings[mapping.repositoryID] = mapping
        try persist()
    }

    public func remove(repository: UUID) throws {
        mappings[repository] = nil
        try persist()
    }

    private func persist() throws {
        try store.save(mappings.values.sorted { $0.assignedAt < $1.assignedAt })
    }
}

/// Supplies per-account tokens. Implemented by `GitHubAuthService`.
public protocol AccountTokenProviding: Sendable {
    func accessToken(for id: AccountID) async throws -> String
    func handleUnauthorized(_ id: AccountID) async
}

extension GitHubAuthService: AccountTokenProviding {}

public struct RepositoryResolution: Sendable, Equatable {
    public var resolution: AccountResolution
    public var githubRepository: ResolvedGitHubRepository?
    /// The remote whose repository receives pull requests.
    public var pullRequestRemote: GitRemote?
    public var remotes: [GitRemote]
    /// Remote name → repository reference for every GitHub remote (used to identify head repositories).
    public var githubRemotes: [String: HostedRepositoryRef]

    public init(
        resolution: AccountResolution,
        githubRepository: ResolvedGitHubRepository? = nil,
        pullRequestRemote: GitRemote? = nil,
        remotes: [GitRemote] = [],
        githubRemotes: [String: HostedRepositoryRef] = [:]
    ) {
        self.resolution = resolution
        self.githubRepository = githubRepository
        self.pullRequestRemote = pullRequestRemote
        self.remotes = remotes
        self.githubRemotes = githubRemotes
    }
}

public enum AccountAssignmentError: Error, Sendable, Equatable, LocalizedError {
    case notGitHub(String)
    case accountNotConnected
    case noAccess(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notGitHub(let detail): "This repository has no usable GitHub remote: \(detail)"
        case .accountNotConnected: "That account is not connected. Reconnect it first."
        case .noAccess(let repository): "That account cannot read \(repository) on GitHub."
        case .verificationFailed(let detail): "Access could not be verified: \(detail)"
        }
    }
}

/// Decides which GitHub account to use for a repository, verifying access through the API.
/// Exactly one eligible account → assigned automatically; several → the user must choose;
/// none → "Needs Account". An existing mapping is never silently replaced by another account.
public actor RepositoryAccountResolver {
    private let configuration: GitHubConfiguration
    private let api: GitHubAPIClient
    private let tokens: any AccountTokenProviding
    private let accounts: GitHubAccountStore
    private let mappings: RepositoryAccountMappingStore
    private let aliasResolver: any SSHHostAliasResolving
    private let now: @Sendable () -> Date

    public init(
        configuration: GitHubConfiguration,
        api: GitHubAPIClient,
        tokens: any AccountTokenProviding,
        accounts: GitHubAccountStore,
        mappings: RepositoryAccountMappingStore,
        aliasResolver: any SSHHostAliasResolving = SSHConfigHostAliasResolver(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.api = api
        self.tokens = tokens
        self.accounts = accounts
        self.mappings = mappings
        self.aliasResolver = aliasResolver
        self.now = now
    }

    // MARK: Remotes

    /// GitHub remotes by name, following SSH host aliases.
    public func githubRemotes(_ remotes: [GitRemote]) async -> [String: HostedRepositoryRef] {
        var result: [String: HostedRepositoryRef] = [:]
        for remote in remotes {
            guard let parsed = RemoteURLParser.parse(remote.url) else { continue }
            var host = parsed.host
            if !configuration.matchesRemoteHost(host), let real = await aliasResolver.hostName(for: host) {
                host = real
            }
            guard configuration.matchesRemoteHost(host) else { continue }
            result[remote.name] = HostedRepositoryRef(host: configuration.host, owner: parsed.owner, name: parsed.name)
        }
        return result
    }

    /// Picks the remote that receives pull requests: the user's override, else `upstream`, else `origin`,
    /// else the only GitHub remote.
    public static func selectPullRequestRemote(
        githubRemotes: [String: HostedRepositoryRef],
        override: String?
    ) -> Result<(name: String, ref: HostedRepositoryRef), AccountAssignmentError> {
        if let override {
            guard let ref = githubRemotes[override] else {
                return .failure(.notGitHub("The remote \"\(override)\" is not a GitHub remote."))
            }
            return .success((override, ref))
        }
        for preferred in ["upstream", "origin"] {
            if let ref = githubRemotes[preferred] {
                return .success((preferred, ref))
            }
        }
        if githubRemotes.count == 1, let only = githubRemotes.first {
            return .success((only.key, only.value))
        }
        if githubRemotes.isEmpty {
            return .failure(.notGitHub("No remote points to github.com."))
        }
        return .failure(.notGitHub("Several GitHub remotes and none is named upstream or origin."))
    }

    // MARK: Resolution

    /// - Parameter allowDiscovery: false immediately before a removal: only an existing, re-verified
    ///   assignment counts, and no account is ever chosen or saved at that point.
    public func resolve(
        _ repository: RegisteredRepository,
        remotes: [GitRemote],
        cachePolicy: GitHubAPIClient.CachePolicy = .revalidate,
        allowDiscovery: Bool = true
    ) async -> RepositoryResolution {
        let githubRemotes = await githubRemotes(remotes)
        let selection: (name: String, ref: HostedRepositoryRef)
        switch Self.selectPullRequestRemote(githubRemotes: githubRemotes, override: repository.pullRequestRemote) {
        case .success(let selected): selection = selected
        case .failure(let error):
            let detail: String
            if case .notGitHub(let message) = error { detail = message } else { detail = error.userMessage }
            return RepositoryResolution(resolution: .notGitHub(detail), remotes: remotes, githubRemotes: githubRemotes)
        }
        let remote = remotes.first { $0.name == selection.name }
        var result = RepositoryResolution(resolution: .needsAccount, pullRequestRemote: remote, remotes: remotes, githubRemotes: githubRemotes)

        if let mapping = await mappings.mapping(for: repository.id) {
            let (resolution, github) = await verifyMapping(mapping, ref: selection.ref, cachePolicy: cachePolicy)
            result.resolution = resolution
            result.githubRepository = github
            return result
        }

        guard allowDiscovery else {
            result.resolution = .unverified("No account is assigned to this repository.")
            return result
        }
        let (resolution, github) = await discover(repository: repository, ref: selection.ref, cachePolicy: cachePolicy)
        result.resolution = resolution
        result.githubRepository = github
        return result
    }

    /// Explicit user choice. Verifies fresh access before persisting; replaces any previous mapping.
    @discardableResult
    public func assign(
        _ accountID: AccountID,
        to repository: RegisteredRepository,
        remotes: [GitRemote]
    ) async throws -> RepositoryAccountMapping {
        let githubRemotes = await githubRemotes(remotes)
        let ref: HostedRepositoryRef
        switch Self.selectPullRequestRemote(githubRemotes: githubRemotes, override: repository.pullRequestRemote) {
        case .success(let selected): ref = selected.ref
        case .failure(let error): throw error
        }
        guard let account = await accounts.account(accountID), account.state.isConnected else {
            throw AccountAssignmentError.accountNotConnected
        }
        let dto: GitHubRepositoryDTO
        do {
            let token = try await tokens.accessToken(for: accountID)
            dto = try await api.repository(ref, token: token, account: accountID, cachePolicy: .fresh)
        } catch GitHubAPIError.notFound, GitHubAPIError.forbidden {
            throw AccountAssignmentError.noAccess(ref.fullName)
        } catch GitHubAPIError.unauthorized {
            await tokens.handleUnauthorized(accountID)
            throw AccountAssignmentError.accountNotConnected
        } catch {
            throw AccountAssignmentError.verificationFailed(error.userMessage)
        }
        guard let pull = dto.permissions?.pull else {
            throw AccountAssignmentError.verificationFailed("GitHub did not report this account's permissions for \(ref.fullName).")
        }
        guard pull else {
            throw AccountAssignmentError.noAccess(ref.fullName)
        }
        let mapping = RepositoryAccountMapping(
            repositoryID: repository.id,
            accountID: accountID,
            githubRepositoryID: dto.id,
            githubFullName: dto.fullName,
            source: .explicit,
            assignedAt: now()
        )
        try await mappings.set(mapping)
        return mapping
    }

    private func verifyMapping(
        _ mapping: RepositoryAccountMapping,
        ref: HostedRepositoryRef,
        cachePolicy: GitHubAPIClient.CachePolicy
    ) async -> (AccountResolution, ResolvedGitHubRepository?) {
        let id = mapping.accountID
        guard let account = await accounts.account(id) else {
            return (.accountUnavailable(id, reason: "It was disconnected."), nil)
        }
        if case .needsReconnect(let reason) = account.state {
            return (.accountUnavailable(id, reason: reason), nil)
        }
        let token: String
        do {
            token = try await tokens.accessToken(for: id)
        } catch {
            return (.accountUnavailable(id, reason: error.userMessage), nil)
        }
        do {
            let dto = try await api.repository(ref, token: token, account: id, cachePolicy: cachePolicy)
            guard dto.id == mapping.githubRepositoryID else {
                return (.accountUnavailable(id, reason: "The remote now points to a different GitHub repository (\(dto.fullName)). Choose the account again."), nil)
            }
            guard let pull = dto.permissions?.pull else {
                return (.unverified("GitHub did not report the account's permissions for \(dto.fullName)."), nil)
            }
            guard pull else {
                return (.accountUnavailable(id, reason: "It can no longer read \(dto.fullName)."), nil)
            }
            return (.assigned(id, automatic: mapping.source == .automatic), dto.resolved(host: configuration.host))
        } catch GitHubAPIError.unauthorized {
            await tokens.handleUnauthorized(id)
            return (.accountUnavailable(id, reason: "GitHub rejected its token."), nil)
        } catch GitHubAPIError.notFound, GitHubAPIError.forbidden {
            return (.accountUnavailable(id, reason: "It can no longer read \(ref.fullName)."), nil)
        } catch {
            return (.unverified(error.userMessage), nil)
        }
    }

    private enum AccessCheck {
        case readable(GitHubRepositoryDTO)
        case noAccess
        case failed(String)
    }

    private func discover(
        repository: RegisteredRepository,
        ref: HostedRepositoryRef,
        cachePolicy: GitHubAPIClient.CachePolicy
    ) async -> (AccountResolution, ResolvedGitHubRepository?) {
        let connected = await accounts.all().filter { $0.state.isConnected && $0.id.host == configuration.host }
        guard !connected.isEmpty else { return (.needsAccount, nil) }

        var readable: [(AccountID, GitHubRepositoryDTO)] = []
        var failures: [String] = []
        // Sequential on purpose: avoids bursts of API calls across accounts.
        for account in connected {
            switch await check(account.id, ref: ref, cachePolicy: cachePolicy) {
            case .readable(let dto): readable.append((account.id, dto))
            case .noAccess: break
            case .failed(let message): failures.append("@\(account.login): \(message)")
            }
        }

        if Set(readable.map { $0.1.id }).count > 1 {
            return (.unverified("Connected accounts see different repositories at \(ref.fullName)."), nil)
        }
        if !failures.isEmpty {
            // Never auto-assign while any account's access is unknown.
            return (.unverified("Could not check every account (\(failures.joined(separator: "; ")))."), nil)
        }
        switch readable.count {
        case 0:
            return (.needsAccount, nil)
        case 1:
            let (accountID, dto) = readable[0]
            let mapping = RepositoryAccountMapping(
                repositoryID: repository.id,
                accountID: accountID,
                githubRepositoryID: dto.id,
                githubFullName: dto.fullName,
                source: .automatic,
                assignedAt: now()
            )
            do {
                try await mappings.set(mapping)
            } catch {
                return (.unverified("The account assignment could not be saved: \(error.userMessage)"), nil)
            }
            return (.assigned(accountID, automatic: true), dto.resolved(host: configuration.host))
        default:
            return (.needsSelection(readable.map(\.0).sorted()), readable[0].1.resolved(host: configuration.host))
        }
    }

    private func check(_ id: AccountID, ref: HostedRepositoryRef, cachePolicy: GitHubAPIClient.CachePolicy) async -> AccessCheck {
        do {
            let token = try await tokens.accessToken(for: id)
            let dto = try await api.repository(ref, token: token, account: id, cachePolicy: cachePolicy)
            switch dto.permissions?.pull {
            case true?: return .readable(dto)
            case false?: return .noAccess
            case nil: return .failed("GitHub did not report the account's permissions.")
            }
        } catch GitHubAPIError.notFound, GitHubAPIError.forbidden {
            return .noAccess
        } catch GitHubAPIError.unauthorized {
            // Unknown, not "no access": the account may well be the right one once reconnected.
            await tokens.handleUnauthorized(id)
            return .failed("GitHub rejected its token")
        } catch {
            return .failed(error.userMessage)
        }
    }
}
