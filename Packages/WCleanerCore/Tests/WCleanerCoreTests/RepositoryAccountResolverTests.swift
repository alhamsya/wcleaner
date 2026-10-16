import XCTest
@testable import WCleanerCore

/// Tokens keyed by account; accounts can be made to fail.
final class FakeTokens: AccountTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [AccountID: String]
    private(set) var unauthorized: [AccountID] = []

    init(_ tokens: [AccountID: String]) {
        self.tokens = tokens
    }

    func accessToken(for id: AccountID) async throws -> String {
        try lock.withLock {
            guard let token = tokens[id] else { throw GitHubAuthError.accountNotFound }
            return token
        }
    }

    func handleUnauthorized(_ id: AccountID) async {
        lock.withLock { unauthorized.append(id) }
    }
}

struct StaticAliasResolver: SSHHostAliasResolving {
    let aliases: [String: String]
    func hostName(for alias: String) async -> String? { aliases[alias] }
}

final class RepositoryAccountResolverTests: XCTestCase {
    private let alice = AccountID(host: "github.com", userID: 1)
    private let bob = AccountID(host: "github.com", userID: 2)
    private var directory: URL!
    private var transport: MockHTTPTransport!
    private var accountStore: GitHubAccountStore!
    private var mappingStore: RepositoryAccountMappingStore!
    private let repository = RegisteredRepository(displayName: "repo", path: "/tmp/repo", commonDirectory: "/tmp/repo/.git")
    private let origin = [GitRemote(name: "origin", url: "git@github.com:octo/repo.git")]
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-resolver-\(UUID().uuidString)")
        let data = AppDataDirectory(url: directory)
        transport = MockHTTPTransport()
        accountStore = GitHubAccountStore(store: JSONFileStore(directory: data, fileName: "accounts.json"))
        mappingStore = RepositoryAccountMappingStore(store: JSONFileStore(directory: data, fileName: "mappings.json"))
        try await accountStore.upsert(GitHubAccount(id: alice, login: "alice"))
        try await accountStore.upsert(GitHubAccount(id: bob, login: "bob"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeResolver(tokens: FakeTokens? = nil, aliases: [String: String] = [:]) -> RepositoryAccountResolver {
        RepositoryAccountResolver(
            configuration: configuration,
            api: GitHubAPIClient(transport: transport, configuration: configuration),
            tokens: tokens ?? FakeTokens([alice: "token-alice", bob: "token-bob"]),
            accounts: accountStore,
            mappings: mappingStore,
            aliasResolver: StaticAliasResolver(aliases: aliases)
        )
    }

    private func grant(_ token: String, repositoryID: Int64 = 10, owner: String = "octo", name: String = "repo") {
        transport.json(path: "/repos/\(owner)/\(name)", token: token, GitHubFixtures.repository(id: repositoryID, owner: owner, name: name))
    }

    private func deny(_ token: String, owner: String = "octo", name: String = "repo") {
        transport.json(path: "/repos/\(owner)/\(name)", token: token, status: 404, "{\"message\":\"Not Found\"}")
    }

    func testExactlyOneEligibleAccountIsAssignedAutomatically() async throws {
        grant("token-alice")
        deny("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .assigned(alice, automatic: true))
        XCTAssertEqual(result.githubRepository?.id, 10)
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertEqual(mapping?.accountID, alice)
        XCTAssertEqual(mapping?.source, .automatic)
        XCTAssertEqual(mapping?.githubRepositoryID, 10)
    }

    func testSeveralEligibleAccountsRequireExplicitSelection() async throws {
        grant("token-alice")
        grant("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .needsSelection([alice, bob]))
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertNil(mapping, "Ambiguity must not be resolved automatically")
    }

    func testNoEligibleAccountNeedsAccount() async throws {
        deny("token-alice")
        deny("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .needsAccount)
    }

    func testNoConnectedAccountsNeedsAccount() async throws {
        try await accountStore.remove(alice)
        try await accountStore.remove(bob)
        let result = await makeResolver().resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .needsAccount)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnknownAccessForAnyAccountBlocksAutomaticAssignment() async throws {
        grant("token-alice")
        transport.on(path: "/repos/octo/repo", token: "token-bob") { _ in (502, [:], Data()) }
        let result = await makeResolver().resolve(repository, remotes: origin)
        guard case .unverified = result.resolution else { return XCTFail("Expected unverified, got \(result.resolution)") }
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertNil(mapping)
    }

    func testRejectedTokenDuringDiscoveryIsInconclusive() async throws {
        grant("token-alice")
        transport.json(path: "/repos/octo/repo", token: "token-bob", status: 401, "{}")
        let tokens = FakeTokens([alice: "token-alice", bob: "token-bob"])
        let result = await makeResolver(tokens: tokens).resolve(repository, remotes: origin)
        guard case .unverified = result.resolution else { return XCTFail("Expected unverified, got \(result.resolution)") }
        XCTAssertEqual(tokens.unauthorized, [bob])
    }

    /// Right before a removal, the existing assignment is verified; no account is discovered or assigned.
    func testWithoutDiscoveryAnUnassignedRepositoryIsUnverified() async throws {
        grant("token-alice")
        deny("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin, cachePolicy: .fresh, allowDiscovery: false)
        guard case .unverified = result.resolution else { return XCTFail("Expected unverified, got \(result.resolution)") }
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertNil(mapping)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMissingPermissionsAreNeverTreatedAsAccess() async throws {
        transport.json(path: "/repos/octo/repo", token: "token-alice",
                       #"{"id": 10, "name": "repo", "full_name": "octo/repo", "owner": {"login": "octo", "id": 5}, "private": true, "fork": false, "html_url": "https://github.com/octo/repo"}"#)
        deny("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin)
        guard case .unverified = result.resolution else { return XCTFail("Expected unverified, got \(result.resolution)") }
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertNil(mapping)
    }

    func testMappedAccountIsNeverReplacedWhenDisconnected() async throws {
        grant("token-alice")
        deny("token-bob")
        _ = await makeResolver().resolve(repository, remotes: origin)

        try await accountStore.remove(alice)
        grant("token-bob")
        let result = await makeResolver(tokens: FakeTokens([bob: "token-bob"])).resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .accountUnavailable(alice, reason: "It was disconnected."))
        XCTAssertNil(result.githubRepository)
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertEqual(mapping?.accountID, alice, "No silent fallback to another account")
    }

    func testMappedAccountThatLosesAccessIsUnavailable() async throws {
        try await mappingStore.set(RepositoryAccountMapping(repositoryID: repository.id, accountID: alice, githubRepositoryID: 10, githubFullName: "octo/repo", source: .explicit, assignedAt: Date()))
        deny("token-alice")
        grant("token-bob")
        let result = await makeResolver().resolve(repository, remotes: origin)
        guard case .accountUnavailable(let id, _) = result.resolution else { return XCTFail("Got \(result.resolution)") }
        XCTAssertEqual(id, alice)
    }

    func testMappedAccountNeedingReconnectIsUnavailable() async throws {
        try await mappingStore.set(RepositoryAccountMapping(repositoryID: repository.id, accountID: alice, githubRepositoryID: 10, githubFullName: "octo/repo", source: .automatic, assignedAt: Date()))
        try await accountStore.update(alice) { $0.state = .needsReconnect(reason: "Its token expired.") }
        let result = await makeResolver().resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .accountUnavailable(alice, reason: "Its token expired."))
    }

    func testTransientErrorKeepsMappingButIsUnverified() async throws {
        try await mappingStore.set(RepositoryAccountMapping(repositoryID: repository.id, accountID: alice, githubRepositoryID: 10, githubFullName: "octo/repo", source: .automatic, assignedAt: Date()))
        transport.on(path: "/repos/octo/repo", token: "token-alice") { _ in (503, [:], Data()) }
        let result = await makeResolver().resolve(repository, remotes: origin)
        guard case .unverified = result.resolution else { return XCTFail("Got \(result.resolution)") }
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertEqual(mapping?.accountID, alice)
    }

    func testRepositoryIdentityChangeInvalidatesMapping() async throws {
        try await mappingStore.set(RepositoryAccountMapping(repositoryID: repository.id, accountID: alice, githubRepositoryID: 10, githubFullName: "octo/repo", source: .automatic, assignedAt: Date()))
        grant("token-alice", repositoryID: 11)
        let result = await makeResolver().resolve(repository, remotes: origin)
        guard case .accountUnavailable(alice, _) = result.resolution else { return XCTFail("Got \(result.resolution)") }
        XCTAssertNil(result.githubRepository)
    }

    func testExplicitAssignmentVerifiesAccessAndPersists() async throws {
        grant("token-alice")
        grant("token-bob")
        let resolver = makeResolver()
        let mapping = try await resolver.assign(bob, to: repository, remotes: origin)
        XCTAssertEqual(mapping.source, .explicit)
        let result = await resolver.resolve(repository, remotes: origin)
        XCTAssertEqual(result.resolution, .assigned(bob, automatic: false))
    }

    func testExplicitAssignmentToAccountWithoutAccessFails() async throws {
        grant("token-alice")
        deny("token-bob")
        let resolver = makeResolver()
        _ = await resolver.resolve(repository, remotes: origin)
        do {
            try await resolver.assign(bob, to: repository, remotes: origin)
            XCTFail("Expected noAccess")
        } catch let error as AccountAssignmentError {
            XCTAssertEqual(error, .noAccess("octo/repo"))
        }
        let mapping = await mappingStore.mapping(for: repository.id)
        XCTAssertEqual(mapping?.accountID, alice, "A failed assignment leaves the previous mapping intact")
    }

    func testNonGitHubRemotesAreReported() async {
        let result = await makeResolver().resolve(repository, remotes: [GitRemote(name: "origin", url: "git@gitlab.com:octo/repo.git")])
        guard case .notGitHub = result.resolution else { return XCTFail("Got \(result.resolution)") }
    }

    func testUpstreamIsPreferredForPullRequestsAndOverrideWins() {
        let remotes = [
            "origin": HostedRepositoryRef(host: "github.com", owner: "me", name: "repo"),
            "upstream": HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo"),
        ]
        XCTAssertEqual(try? RepositoryAccountResolver.selectPullRequestRemote(githubRemotes: remotes, override: nil).get().name, "upstream")
        XCTAssertEqual(try? RepositoryAccountResolver.selectPullRequestRemote(githubRemotes: remotes, override: "origin").get().name, "origin")
        XCTAssertNil(try? RepositoryAccountResolver.selectPullRequestRemote(githubRemotes: remotes, override: "missing").get())

        let ambiguous = [
            "a": HostedRepositoryRef(host: "github.com", owner: "x", name: "repo"),
            "b": HostedRepositoryRef(host: "github.com", owner: "y", name: "repo"),
        ]
        XCTAssertNil(try? RepositoryAccountResolver.selectPullRequestRemote(githubRemotes: ambiguous, override: nil).get())
    }

    func testSSHHostAliasesAreFollowed() async {
        let resolver = makeResolver(aliases: ["github-work": "github.com"])
        let remotes = await resolver.githubRemotes([
            GitRemote(name: "origin", url: "git@github-work:octo/repo.git"),
            GitRemote(name: "other", url: "git@unknown-alias:octo/repo.git"),
        ])
        XCTAssertEqual(remotes, ["origin": HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo")])
    }
}

final class SSHConfigParserTests: XCTestCase {
    func testResolvesHostNameForAliases() {
        let config = """
        # Work account
        Host github-work
            HostName github.com
            IdentityFile ~/.ssh/work

        Host *.corp !secret.corp
          HostName=%h.example.com

        Host personal gh-personal
          Hostname "github.com"

        Match exec "touch /tmp/should-never-run"
          HostName evil.example
        """
        XCTAssertEqual(SSHConfigParser.hostName(for: "github-work", configText: config), "github.com")
        XCTAssertEqual(SSHConfigParser.hostName(for: "gh-personal", configText: config), "github.com")
        XCTAssertEqual(SSHConfigParser.hostName(for: "build.corp", configText: config), "build.corp.example.com")
        XCTAssertNil(SSHConfigParser.hostName(for: "secret.corp", configText: config))
        XCTAssertNil(SSHConfigParser.hostName(for: "unknown", configText: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/should-never-run"))
    }
}
