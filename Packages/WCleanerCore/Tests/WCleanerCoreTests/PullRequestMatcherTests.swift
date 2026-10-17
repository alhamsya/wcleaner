import XCTest
@testable import WCleanerCore

final class PullRequestMatcherTests: XCTestCase {
    private let account = AccountID(host: "github.com", userID: 1)
    private let head = String(repeating: "a", count: 40)
    private let otherHead = String(repeating: "b", count: 40)
    private let base = ResolvedGitHubRepository(id: 10, owner: "octo", name: "repo", htmlURL: "https://github.com/octo/repo")
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")
    private var transport: MockHTTPTransport!

    override func setUp() {
        transport = MockHTTPTransport()
    }

    private var matcher: PullRequestMatcher {
        PullRequestMatcher(
            api: GitHubAPIClient(transport: transport, configuration: configuration),
            tokens: FakeTokens([account: "token"])
        )
    }

    private func lookup(branch: String = "feature", upstream: BranchUpstream? = nil, remotes: [String: HostedRepositoryRef]? = nil) -> PullRequestLookup {
        PullRequestLookup(
            baseRepository: base,
            account: account,
            localBranch: branch,
            localHead: head,
            upstream: upstream,
            githubRemotes: remotes ?? ["origin": HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo")]
        )
    }

    private func respond(head expectedHead: String, with pulls: [String]) {
        transport.on({ request in
            request.url?.path == "/repos/octo/repo/pulls"
                && (request.url?.query?.removingPercentEncoding?.contains("head=\(expectedHead)") ?? false)
        }) { _ in (200, [:], Data("[\(pulls.joined(separator: ","))]".utf8)) }
    }

    private func pull(_ number: Int, state: String = "closed", merged: Bool = true, sha: String? = nil, headRef: String = "feature", headRepo: (Int64, String)? = (10, "octo/repo"), baseRepo: (Int64, String) = (10, "octo/repo")) -> String {
        GitHubFixtures.pullRequest(
            number: number,
            state: state,
            mergedAt: merged ? "2026-05-01T10:00:00Z" : nil,
            headSHA: sha ?? head,
            headRef: headRef,
            headRepo: headRepo,
            baseRepo: baseRepo
        )
    }

    func testSameRepositoryMergedPullRequest() async {
        respond(head: "octo:feature", with: [pull(5)])
        let match = await matcher.match(lookup())
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertEqual(evidence.number, 5)
        XCTAssertEqual(evidence.state, .merged)
        XCTAssertTrue(evidence.headRepositoryVerified)
        XCTAssertEqual(evidence.accountID, account)
        XCTAssertEqual(evidence.url, "https://github.com/octo/repo/pull/5")
        XCTAssertEqual(match.summary, "PR #5 Merged")
    }

    func testForkPullRequestUsesUpstreamRemoteAndRenamedBranch() async {
        let remotes = [
            "origin": HostedRepositoryRef(host: "github.com", owner: "me", name: "repo-fork"),
            "upstream": HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo"),
        ]
        respond(head: "me:feat/renamed", with: [pull(8, headRef: "feat/renamed", headRepo: (77, "me/repo-fork"))])
        let match = await matcher.match(lookup(
            branch: "local-name",
            upstream: BranchUpstream(remoteName: "origin", remoteBranch: "feat/renamed"),
            remotes: remotes
        ))
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertEqual(evidence.number, 8)
        XCTAssertEqual(evidence.headRepositoryID, 77)
        XCTAssertTrue(evidence.headRepositoryVerified)
    }

    func testForkHeadRepositoryMismatchIsNotVerified() async {
        let remotes = [
            "origin": HostedRepositoryRef(host: "github.com", owner: "me", name: "repo-fork"),
            "upstream": HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo"),
        ]
        respond(head: "me:feature", with: [pull(8, headRepo: (99, "someone-else/repo"))])
        let match = await matcher.match(lookup(upstream: BranchUpstream(remoteName: "origin", remoteBranch: "feature"), remotes: remotes))
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertFalse(evidence.headRepositoryVerified)
    }

    func testRenamedBranchFoundByCommit() async {
        respond(head: "octo:feature", with: [])
        transport.json(path: "/repos/octo/repo/commits/\(head)/pulls", "[\(pull(12, headRef: "totally-different"))]")
        let match = await matcher.match(lookup())
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertEqual(evidence.number, 12)
        XCTAssertTrue(evidence.headRepositoryVerified)
    }

    func testCommitLookupFromUnknownForkIsNotVerified() async {
        respond(head: "octo:feature", with: [])
        transport.json(path: "/repos/octo/repo/commits/\(head)/pulls", "[\(pull(13, headRepo: (500, "stranger/repo")))]")
        let match = await matcher.match(lookup())
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertFalse(evidence.headRepositoryVerified)
    }

    func testBranchMatchWithDifferentHeadIsAMismatch() async {
        respond(head: "octo:feature", with: [pull(5, sha: otherHead)])
        transport.json(path: "/repos/octo/repo/commits/\(head)/pulls", "[]")
        let match = await matcher.match(lookup())
        guard case .headMismatch(let evidence, let local) = match else { return XCTFail("Got \(match)") }
        XCTAssertEqual(evidence.number, 5)
        XCTAssertEqual(local, head)
        XCTAssertEqual(match.summary, "PR #5 Merged, different HEAD")
    }

    func testReusedBranchNamePicksTheExactHead() async {
        respond(head: "octo:feature", with: [pull(5, sha: otherHead), pull(9, state: "open", merged: false)])
        let match = await matcher.match(lookup())
        guard case .matched(let evidence) = match else { return XCTFail("Got \(match)") }
        XCTAssertEqual(evidence.number, 9)
        XCTAssertEqual(evidence.state, .open)
    }

    func testDuplicatePullRequestsForSameHeadAreAmbiguous() async {
        respond(head: "octo:feature", with: [pull(5, merged: false), pull(6)])
        let match = await matcher.match(lookup())
        XCTAssertEqual(match, .ambiguous([5, 6]))
        XCTAssertEqual(match.summary, "2 possible PRs")
    }

    func testPullRequestsToOtherBaseRepositoriesAreIgnored() async {
        respond(head: "octo:feature", with: [pull(5, baseRepo: (999, "octo/repo"))])
        transport.json(path: "/repos/octo/repo/commits/\(head)/pulls", "[]")
        let match = await matcher.match(lookup())
        XCTAssertEqual(match, .notFound)
        XCTAssertEqual(match.summary, "No PR")
    }

    func testClosedUnmergedIsReportedAsSuch() async {
        respond(head: "octo:feature", with: [pull(5, merged: false)])
        let match = await matcher.match(lookup())
        XCTAssertEqual(match.evidence?.state, .closedUnmerged)
        XCTAssertEqual(match.summary, "PR #5 Closed Unmerged")
    }

    func testErrorsBecomeUnavailableAndUnauthorizedIsReported() async {
        transport.on(path: "/repos/octo/repo/pulls") { _ in (500, [:], Data()) }
        guard case .unavailable = await matcher.match(lookup()) else { return XCTFail("Expected unavailable") }

        let tokens = FakeTokens([account: "token"])
        let unauthorizedTransport = MockHTTPTransport()
        unauthorizedTransport.on(path: "/repos/octo/repo/pulls") { _ in (401, [:], Data()) }
        let matcher = PullRequestMatcher(api: GitHubAPIClient(transport: unauthorizedTransport, configuration: configuration), tokens: tokens)
        guard case .unavailable = await matcher.match(lookup()) else { return XCTFail("Expected unavailable") }
        XCTAssertEqual(tokens.unauthorized, [account])
    }

    func testFreshEvidenceBypassesCache() async throws {
        let body = pull(5)
        transport.on(path: "/repos/octo/repo/pulls/5") { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return (200, ["ETag": "\"x\""], Data(body.utf8))
        }
        let evidence = try await matcher.freshEvidence(number: 5, baseRepository: base, account: account, expectedHeadRepositoryFullName: "octo/repo")
        XCTAssertEqual(evidence.state, .merged)
        XCTAssertTrue(evidence.headRepositoryVerified)
        let again = try await matcher.freshEvidence(number: 5, baseRepository: base, account: account, expectedHeadRepositoryFullName: nil)
        XCTAssertFalse(again.headRepositoryVerified)
    }

    func testHeadCandidatesAreBounded() {
        var remotes: [String: HostedRepositoryRef] = [:]
        for index in 0..<10 {
            remotes["fork\(index)"] = HostedRepositoryRef(host: "github.com", owner: "owner\(index)", name: "repo")
        }
        XCTAssertLessThanOrEqual(matcher.headCandidates(lookup(remotes: remotes)).count, 4)
    }
}
