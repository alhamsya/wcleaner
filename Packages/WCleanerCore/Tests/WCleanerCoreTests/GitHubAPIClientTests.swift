import XCTest
@testable import WCleanerCore

final class GitHubAPIClientTests: XCTestCase {
    private let alice = AccountID(host: "github.com", userID: 1)
    private let bob = AccountID(host: "github.com", userID: 2)
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST", userAgent: "WCleaner-Tests")
    private let repo = HostedRepositoryRef(host: "github.com", owner: "octo", name: "repo")

    func testSendsVersionedAuthenticatedRequests() async throws {
        let transport = MockHTTPTransport()
        transport.json(path: "/user", GitHubFixtures.user(id: 1, login: "alice"))
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        let user = try await client.currentUser(token: "ghu_alice")
        XCTAssertEqual(user.id, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "api.github.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghu_alice")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testETagRevalidationReusesCachedBodyPerAccount() async throws {
        let transport = MockHTTPTransport()
        let body = GitHubFixtures.repository(id: 10, owner: "octo", name: "repo")
        transport.on(path: "/repos/octo/repo") { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return (304, [:], Data())
            }
            return (200, ["ETag": "\"v1\""], Data(body.utf8))
        }
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        let first = try await client.repository(repo, token: "a", account: alice)
        let second = try await client.repository(repo, token: "a", account: alice)
        XCTAssertEqual(first, second)
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")

        _ = try await client.repository(repo, token: "b", account: bob)
        XCTAssertNil(transport.requests[2].value(forHTTPHeaderField: "If-None-Match"), "Cache entries are never shared across accounts")

        _ = try await client.repository(repo, token: "a", account: alice, cachePolicy: .fresh)
        XCTAssertNil(transport.requests[3].value(forHTTPHeaderField: "If-None-Match"), "Fresh evidence must bypass the cache")
    }

    func testRateLimitIsTrackedPerAccount() async throws {
        let transport = MockHTTPTransport()
        let reset = Date().addingTimeInterval(600)
        transport.on({ $0.value(forHTTPHeaderField: "Authorization") == "Bearer a" }) { _ in
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(reset.timeIntervalSince1970))], Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        }
        transport.json(path: "/repos/octo/repo", token: "b", GitHubFixtures.repository(id: 10, owner: "octo", name: "repo"))
        let client = GitHubAPIClient(transport: transport, configuration: configuration)

        await XCTAssertThrowsErrorAsync(try await client.repository(repo, token: "a", account: alice))
        let countAfterFirst = transport.requests.count
        do {
            _ = try await client.repository(repo, token: "a", account: alice)
            XCTFail("Expected rate limit")
        } catch GitHubAPIError.rateLimited(let resetAt) {
            XCTAssertNotNil(resetAt)
        }
        XCTAssertEqual(transport.requests.count, countAfterFirst, "No request is sent while an account is rate limited")

        let other = try await client.repository(repo, token: "b", account: bob)
        XCTAssertEqual(other.id, 10, "Another account is unaffected")
    }

    func testSecondaryRateLimitUsesRetryAfter() async {
        let transport = MockHTTPTransport()
        transport.on(path: "/repos/octo/repo") { _ in (403, ["Retry-After": "60"], Data("{}".utf8)) }
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        do {
            _ = try await client.repository(repo, token: "a", account: alice)
            XCTFail("Expected rate limit")
        } catch GitHubAPIError.rateLimited(let resetAt) {
            XCTAssertNotNil(resetAt)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testStatusCodesMapToErrors() async {
        let cases: [(Int, GitHubAPIError)] = [
            (401, .unauthorized), (403, .forbidden("nope")), (404, .notFound), (500, .server(500)),
        ]
        for (status, expected) in cases {
            let transport = MockHTTPTransport()
            transport.on(path: "/repos/octo/repo") { _ in (status, [:], Data("{\"message\":\"nope\"}".utf8)) }
            let client = GitHubAPIClient(transport: transport, configuration: configuration)
            do {
                _ = try await client.repository(repo, token: "a", account: alice)
                XCTFail("Expected \(expected)")
            } catch let error as GitHubAPIError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }

    func testHeadQueryIsStrictlyPercentEncoded() async throws {
        let transport = MockHTTPTransport()
        transport.json(path: "/repos/octo/repo/pulls", "[]")
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        _ = try await client.pullRequests(base: repo, headOwner: "fork-owner", headBranch: "feat/a+b&c=d #1", token: "a", account: alice)
        let query = try XCTUnwrap(transport.requests.first?.url?.query)
        XCTAssertTrue(query.contains("head=fork-owner%3Afeat%2Fa%2Bb%26c%3Dd%20%231"), query)
        XCTAssertTrue(query.contains("state=all"))
    }

    func testRejectsUnsafeRepositoryReferences() async {
        let client = GitHubAPIClient(transport: MockHTTPTransport(), configuration: configuration)
        await XCTAssertThrowsErrorAsync(try await client.repository(HostedRepositoryRef(host: "github.com", owner: "..", name: "x"), token: "a", account: self.alice))
        await XCTAssertThrowsErrorAsync(try await client.repository(HostedRepositoryRef(host: "evil.example", owner: "o", name: "r"), token: "a", account: self.alice))
    }

    func testUnknownCommitMeansNoPullRequests() async throws {
        let transport = MockHTTPTransport()
        let sha = String(repeating: "c", count: 40)
        transport.json(path: "/repos/octo/repo/commits/\(sha)/pulls", status: 422, "{\"message\":\"No commit found\"}")
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        let pulls = try await client.pullRequests(base: repo, commit: sha, token: "a", account: alice)
        XCTAssertTrue(pulls.isEmpty)
    }

    func testDecodesPullRequestEvidence() async throws {
        let transport = MockHTTPTransport()
        let sha = String(repeating: "a", count: 40)
        transport.json(path: "/repos/octo/repo/pulls/7", GitHubFixtures.pullRequest(
            number: 7, state: "closed", mergedAt: "2026-01-02T03:04:05Z", headSHA: sha, headRef: "feature",
            headRepo: (99, "fork/repo"), baseRepo: (10, "octo/repo")
        ))
        let client = GitHubAPIClient(transport: transport, configuration: configuration)
        let dto = try await client.pullRequest(base: repo, number: 7, token: "a", account: alice, cachePolicy: .fresh)
        let evidence = dto.evidence(account: alice, fetchedAt: Date(), expectedHeadRepository: HostedRepositoryRef(host: "github.com", owner: "fork", name: "repo"))
        XCTAssertEqual(evidence.state, .merged)
        XCTAssertEqual(evidence.headSHA, sha)
        XCTAssertEqual(evidence.baseRepositoryID, 10)
        XCTAssertEqual(evidence.headRepositoryID, 99)
        XCTAssertTrue(evidence.headRepositoryVerified)

        let mismatched = dto.evidence(account: alice, fetchedAt: Date(), expectedHeadRepository: HostedRepositoryRef(host: "github.com", owner: "someone", name: "repo"))
        XCTAssertFalse(mismatched.headRepositoryVerified)

        let unknown = dto.evidence(account: alice, fetchedAt: Date(), expectedHeadRepository: nil)
        XCTAssertFalse(unknown.headRepositoryVerified, "Without an expected head repository nothing is verified")
    }
}

final class GitHubDeviceFlowTests: XCTestCase {
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")

    func testNotConfiguredWithoutClientID() async {
        for clientID in [nil, "", "   ", "$(WCLEANER_GITHUB_CLIENT_ID)"] {
            let config = GitHubConfiguration(clientID: clientID)
            XCTAssertFalse(config.isConfigured, "\(String(describing: clientID))")
            let flow = GitHubDeviceFlow(transport: MockHTTPTransport(), configuration: config)
            do {
                _ = try await flow.start()
                XCTFail("Expected notConfigured")
            } catch let error as DeviceFlowError {
                XCTAssertEqual(error, .notConfigured)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }
    }

    func testStartRequestsCodeWithoutSecretOrScopeForGitHubApps() async throws {
        let transport = MockHTTPTransport()
        transport.json(path: "/login/device/code", #"{"device_code":"dev","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        let authorization = try await GitHubDeviceFlow(transport: transport, configuration: configuration).start()
        XCTAssertEqual(authorization.userCode, "ABCD-1234")
        XCTAssertEqual(authorization.verificationURI.absoluteString, "https://github.com/login/device")
        let body = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(body, "client_id=Iv23liTEST")
        XCTAssertFalse(body.contains("secret"))
    }

    func testOAuthAppRequestsRepoScope() async throws {
        let transport = MockHTTPTransport()
        transport.json(path: "/login/device/code", #"{"device_code":"dev","user_code":"X","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        _ = try await GitHubDeviceFlow(transport: transport, configuration: GitHubConfiguration(clientID: "Ov23liOAUTH")).start()
        XCTAssertEqual(String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self), "client_id=Ov23liOAUTH&scope=repo")
    }

    func testPollingHonorsPendingAndSlowDown() async throws {
        let transport = MockHTTPTransport()
        let responses = ResponseQueue([
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"ghu_new","token_type":"bearer","scope":"","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600}"#,
        ])
        transport.on(path: "/login/oauth/access_token") { _ in (200, [:], Data(responses.next().utf8)) }
        let sleeper = RecordingSleeper()
        let flow = GitHubDeviceFlow(transport: transport, configuration: configuration, sleeper: sleeper)
        let authorization = DeviceAuthorization(deviceCode: "dev", userCode: "X", verificationURI: URL(string: "https://github.com/login/device")!, expiresAt: Date().addingTimeInterval(900), interval: 5)
        let token = try await flow.poll(authorization)
        XCTAssertEqual(token.accessToken, "ghu_new")
        XCTAssertEqual(token.refreshToken, "ghr_new")
        XCTAssertNotNil(token.expiresAt)
        XCTAssertEqual(sleeper.durations, [.seconds(5), .seconds(5), .seconds(10)])
        XCTAssertFalse(String(describing: token).contains("ghu_new"), "Token descriptions must be redacted")
        let body = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
    }

    func testPollingStopsOnDenialAndExpiry() async {
        for (error, expected) in [("access_denied", DeviceFlowError.accessDenied), ("expired_token", .expired), ("device_flow_disabled", .deviceFlowDisabled)] {
            let transport = MockHTTPTransport()
            transport.json(path: "/login/oauth/access_token", #"{"error":"\#(error)"}"#)
            let flow = GitHubDeviceFlow(transport: transport, configuration: configuration, sleeper: RecordingSleeper())
            let authorization = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: URL(string: "https://github.com/login/device")!, expiresAt: Date().addingTimeInterval(900), interval: 5)
            do {
                _ = try await flow.poll(authorization)
                XCTFail("Expected \(expected)")
            } catch let caught as DeviceFlowError {
                XCTAssertEqual(caught, expected)
            } catch {
                XCTFail("Unexpected \(error)")
            }
        }

        let flow = GitHubDeviceFlow(transport: MockHTTPTransport(), configuration: configuration, sleeper: RecordingSleeper())
        let expired = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: URL(string: "https://github.com/login/device")!, expiresAt: Date().addingTimeInterval(-1), interval: 5)
        do {
            _ = try await flow.poll(expired)
            XCTFail("Expected expiry")
        } catch {
            XCTAssertEqual(error as? DeviceFlowError, .expired)
        }
    }
}

final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    func next() -> String {
        lock.withLock { items.count > 1 ? items.removeFirst() : items[0] }
    }
}
