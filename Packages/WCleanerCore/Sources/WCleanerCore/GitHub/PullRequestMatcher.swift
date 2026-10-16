import Foundation

/// Everything needed to find the pull request for one worktree.
public struct PullRequestLookup: Sendable, Equatable {
    public var baseRepository: ResolvedGitHubRepository
    public var account: AccountID
    public var localBranch: String
    public var localHead: String
    public var upstream: BranchUpstream?
    /// Remote name → repository reference for every GitHub remote of the local repository.
    public var githubRemotes: [String: HostedRepositoryRef]

    public init(
        baseRepository: ResolvedGitHubRepository,
        account: AccountID,
        localBranch: String,
        localHead: String,
        upstream: BranchUpstream?,
        githubRemotes: [String: HostedRepositoryRef]
    ) {
        self.baseRepository = baseRepository
        self.account = account
        self.localBranch = localBranch
        self.localHead = localHead
        self.upstream = upstream
        self.githubRemotes = githubRemotes
    }
}

/// Associates a worktree with exactly one pull request, or explains why it cannot.
///
/// A candidate must target the canonical base repository (by numeric ID), and its head SHA must equal the
/// worktree HEAD exactly. Branch names are only used to find candidates, never as proof: forks, renamed
/// branches and reused branch names are handled by checking repository IDs and SHAs.
public struct PullRequestMatcher: Sendable {
    private let api: GitHubAPIClient
    private let tokens: any AccountTokenProviding
    private let now: @Sendable () -> Date

    public init(api: GitHubAPIClient, tokens: any AccountTokenProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.tokens = tokens
        self.now = now
    }

    public func match(_ lookup: PullRequestLookup) async -> PullRequestMatch {
        guard GitObjectID.isValid(lookup.localHead) else {
            return .unavailable("The worktree HEAD is not a valid commit.")
        }
        let token: String
        do {
            token = try await tokens.accessToken(for: lookup.account)
        } catch {
            return .unavailable(error.userMessage)
        }

        do {
            let base = lookup.baseRepository.ref
            var candidates: [(dto: GitHubPullRequestDTO, expectedHead: HostedRepositoryRef?)] = []
            for head in headCandidates(lookup) {
                let pulls = try await api.pullRequests(
                    base: base,
                    headOwner: head.owner,
                    headBranch: head.branch,
                    token: token,
                    account: lookup.account
                )
                for pull in pulls where pull.base.repo?.id == lookup.baseRepository.id {
                    if !candidates.contains(where: { $0.dto.number == pull.number }) {
                        candidates.append((pull, head.repository))
                    }
                }
                if candidates.contains(where: { $0.dto.head.sha == lookup.localHead }) {
                    break
                }
            }

            let exact = candidates.filter { $0.dto.head.sha == lookup.localHead }
            if exact.count == 1 {
                return .matched(exact[0].dto.evidence(account: lookup.account, fetchedAt: now(), expectedHeadRepository: exact[0].expectedHead))
            }
            if exact.count > 1 {
                return .ambiguous(exact.map(\.dto.number).sorted())
            }

            // The branch may have been renamed: look the commit up directly.
            let byCommit = try await api.pullRequests(base: base, commit: lookup.localHead, token: token, account: lookup.account)
                .filter { $0.base.repo?.id == lookup.baseRepository.id && $0.head.sha == lookup.localHead }
            if byCommit.count == 1 {
                let pull = byCommit[0]
                // Only trust the head repository if it is one of this repository's own remotes.
                let knownHead = pull.head.repo.flatMap { repo in
                    lookup.githubRemotes.values.first { $0.fullName.lowercased() == repo.fullName.lowercased() }
                }
                var evidence = pull.evidence(account: lookup.account, fetchedAt: now(), expectedHeadRepository: knownHead)
                if knownHead == nil { evidence.headRepositoryVerified = false }
                return .matched(evidence)
            }
            if byCommit.count > 1 {
                return .ambiguous(byCommit.map(\.number).sorted())
            }

            if let newest = candidates.max(by: { $0.dto.number < $1.dto.number }) {
                let evidence = newest.dto.evidence(account: lookup.account, fetchedAt: now(), expectedHeadRepository: newest.expectedHead)
                return .headMismatch(evidence, localHead: lookup.localHead)
            }
            return .notFound
        } catch GitHubAPIError.unauthorized {
            await tokens.handleUnauthorized(lookup.account)
            return .unavailable(GitHubAPIError.unauthorized.userMessage)
        } catch {
            return .unavailable(error.userMessage)
        }
    }

    /// Fetches one pull request again, bypassing every cache. Used immediately before removal.
    public func freshEvidence(
        number: Int,
        baseRepository: ResolvedGitHubRepository,
        account: AccountID,
        expectedHeadRepositoryFullName: String?
    ) async throws -> PullRequestEvidence {
        let token = try await tokens.accessToken(for: account)
        do {
            let dto = try await api.pullRequest(base: baseRepository.ref, number: number, token: token, account: account, cachePolicy: .fresh)
            let expected = expectedHeadRepositoryFullName.flatMap { name -> HostedRepositoryRef? in
                let parts = name.split(separator: "/")
                guard parts.count == 2 else { return nil }
                return HostedRepositoryRef(host: baseRepository.host, owner: String(parts[0]), name: String(parts[1]))
            }
            var evidence = dto.evidence(account: account, fetchedAt: now(), expectedHeadRepository: expected)
            if expectedHeadRepositoryFullName == nil { evidence.headRepositoryVerified = false }
            return evidence
        } catch GitHubAPIError.unauthorized {
            await tokens.handleUnauthorized(account)
            throw GitHubAPIError.unauthorized
        }
    }

    struct HeadCandidate: Equatable {
        let owner: String
        let branch: String
        let repository: HostedRepositoryRef?
    }

    /// Where the branch was most likely pushed: its configured upstream first, then the base
    /// repository, then the other GitHub remotes (forks), all with bounded fan-out.
    func headCandidates(_ lookup: PullRequestLookup) -> [HeadCandidate] {
        var result: [HeadCandidate] = []
        func add(_ candidate: HeadCandidate) {
            if !result.contains(candidate) { result.append(candidate) }
        }
        if let upstream = lookup.upstream, let remote = lookup.githubRemotes[upstream.remoteName] {
            add(HeadCandidate(owner: remote.owner, branch: upstream.remoteBranch, repository: remote))
        }
        let baseRef = lookup.baseRepository.ref
        add(HeadCandidate(owner: baseRef.owner, branch: lookup.localBranch, repository: baseRef))
        for name in lookup.githubRemotes.keys.sorted() {
            guard let remote = lookup.githubRemotes[name], !remote.matches(baseRef) else { continue }
            add(HeadCandidate(owner: remote.owner, branch: lookup.localBranch, repository: remote))
        }
        return Array(result.prefix(4))
    }
}
