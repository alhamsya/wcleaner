import Foundation

/// Wire formats for the few GitHub REST endpoints WCleaner reads.
public struct GitHubUserDTO: Decodable, Sendable, Equatable {
    public let id: Int64
    public let login: String
    public let name: String?
}

public struct GitHubOwnerDTO: Decodable, Sendable, Equatable {
    public let login: String
    public let id: Int64?
}

public struct GitHubPermissionsDTO: Decodable, Sendable, Equatable {
    public let pull: Bool?
    public let push: Bool?
    public let admin: Bool?
}

public struct GitHubRepositoryParentDTO: Decodable, Sendable, Equatable {
    public let id: Int64
    public let fullName: String
}

public struct GitHubRepositoryDTO: Decodable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let fullName: String
    public let owner: GitHubOwnerDTO
    public let isPrivate: Bool
    public let fork: Bool
    public let htmlUrl: String
    public let parent: GitHubRepositoryParentDTO?
    public let permissions: GitHubPermissionsDTO?

    enum CodingKeys: String, CodingKey {
        case id, name, fullName, owner, fork, htmlUrl, parent, permissions
        case isPrivate = "private"
    }

    public func resolved(host: String) -> ResolvedGitHubRepository {
        ResolvedGitHubRepository(
            id: id,
            host: host,
            owner: owner.login,
            name: name,
            htmlURL: htmlUrl,
            isPrivate: isPrivate,
            isFork: fork,
            parentFullName: parent?.fullName
        )
    }
}

public struct GitHubRepoRefDTO: Decodable, Sendable, Equatable {
    public let id: Int64
    public let fullName: String
}

public struct GitHubPullRequestRefDTO: Decodable, Sendable, Equatable {
    public let ref: String
    public let sha: String
    public let repo: GitHubRepoRefDTO?
}

public struct GitHubPullRequestDTO: Decodable, Sendable, Equatable {
    public let number: Int
    public let title: String
    public let htmlUrl: String
    public let state: String
    public let mergedAt: Date?
    public let head: GitHubPullRequestRefDTO
    public let base: GitHubPullRequestRefDTO

    public func evidence(account: AccountID, fetchedAt: Date, expectedHeadRepository: HostedRepositoryRef?) -> PullRequestEvidence {
        let headRepoVerified: Bool
        if let repo = head.repo {
            // Without an independently known head repository there is nothing to verify against.
            headRepoVerified = expectedHeadRepository.map { repo.fullName.lowercased() == $0.fullName.lowercased() } ?? false
        } else {
            headRepoVerified = false
        }
        return PullRequestEvidence(
            number: number,
            title: title,
            url: htmlUrl,
            state: PullRequestState.from(apiState: state, mergedAt: mergedAt),
            mergedAt: mergedAt,
            headSHA: head.sha,
            headRef: head.ref,
            headRepositoryID: head.repo?.id,
            headRepositoryFullName: head.repo?.fullName,
            baseRepositoryID: base.repo?.id ?? -1,
            baseRef: base.ref,
            accountID: account,
            fetchedAt: fetchedAt,
            headRepositoryVerified: headRepoVerified
        )
    }
}

struct GitHubErrorDTO: Decodable {
    let message: String?
}
