import XCTest
@testable import WCleanerCore

/// Answers `gh` invocations from a script and records them; never starts a process.
final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ProcessRequest] = []
    private var _respond: @Sendable (ProcessRequest) throws -> ProcessResult

    init(_ respond: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) {
        _respond = respond
    }

    var requests: [ProcessRequest] { lock.withLock { _requests } }

    func setResponder(_ respond: @escaping @Sendable (ProcessRequest) throws -> ProcessResult) {
        lock.withLock { _respond = respond }
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let respond = lock.withLock { () -> @Sendable (ProcessRequest) throws -> ProcessResult in
            _requests.append(request)
            return _respond
        }
        return try respond(request)
    }
}

private func output(_ text: String, exit: Int32 = 0, stderr: String = "") -> ProcessResult {
    ProcessResult(exitCode: exit, stdout: Data(text.utf8), stderr: Data(stderr.utf8))
}

private let statusJSON = """
{"hosts":{"github.com":[
 {"active":true,"gitProtocol":"https","host":"github.com","login":"alice","scopes":"'gist', 'read:org', 'repo'","state":"success","tokenSource":"keyring"},
 {"active":false,"gitProtocol":"https","host":"github.com","login":"bob","scopes":"'repo'","state":"error","tokenSource":"keyring"}
],"ghe.example.com":[{"active":true,"host":"ghe.example.com","login":"carol","state":"success"}]}}
"""

private let aliceToken = "gho_cliAliceToken0000000000"
private let aliceTokenRotated = "gho_cliAliceToken1111111111"
private let mallory = "gho_cliMalloryToken000000000"

final class GitHubCLITests: XCTestCase {
    private func cli(_ runner: ScriptedProcessRunner, installed: Bool = true, environment: [String: String] = [:]) -> GitHubCLI {
        GitHubCLI(
            runner: runner,
            candidates: ["/opt/homebrew/bin/gh"],
            isExecutable: { _ in installed },
            baseEnvironment: environment
        )
    }

    func testListsOnlyThisHostsAccountsWithoutTokens() async throws {
        let runner = ScriptedProcessRunner { _ in output(statusJSON) }
        let accounts = try await cli(runner).accounts()
        XCTAssertEqual(accounts, [
            GitHubCLIAccount(login: "alice", isActive: true, isUsable: true, scopes: ["gist", "read:org", "repo"]),
            GitHubCLIAccount(login: "bob", isActive: false, isUsable: false, scopes: ["repo"]),
        ])
        XCTAssertEqual(runner.requests.first?.arguments, ["auth", "status", "--hostname", "github.com", "--json", "hosts"])
        XCTAssertEqual(runner.requests.first?.executableURL.path, "/opt/homebrew/bin/gh")
    }

    func testEnvironmentNeverPassesTokenOrHostOverrides() async throws {
        let runner = ScriptedProcessRunner { _ in output(aliceToken + "\n") }
        let base = ["HOME": "/Users/me", "USER": "me", "GH_TOKEN": "x", "GITHUB_TOKEN": "y", "GH_HOST": "evil.example", "GH_CONFIG_DIR": "/tmp/x"]
        _ = try await cli(runner, environment: base).token(for: "alice")
        let environment = try XCTUnwrap(runner.requests.first?.environment)
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertNil(environment["GH_TOKEN"])
        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertNil(environment["GH_HOST"])
        XCTAssertNil(environment["GH_CONFIG_DIR"])
        XCTAssertEqual(environment["GH_PROMPT_DISABLED"], "1")
    }

    func testTokenIsForTheNamedUserAndIsValidated() async throws {
        let runner = ScriptedProcessRunner { _ in output(aliceToken + "\n") }
        let token = try await cli(runner).token(for: "alice")
        XCTAssertEqual(token, aliceToken)
        XCTAssertEqual(runner.requests.first?.arguments, ["auth", "token", "--hostname", "github.com", "--user", "alice"])

        runner.setResponder { _ in output("Welcome to gh! not a token\n") }
        do {
            _ = try await cli(runner).token(for: "alice")
            XCTFail("Expected an error")
        } catch let error as GitHubCLIError {
            guard case .tokenUnavailable(let login, _) = error else { return XCTFail("Got \(error)") }
            XCTAssertEqual(login, "alice")
        }
    }

    func testFailuresNeverEchoATokenAndExplainWhatToDo() async throws {
        let runner = ScriptedProcessRunner { _ in output("", exit: 1, stderr: "no oauth token found for github.com account alice\n") }
        do {
            _ = try await cli(runner).token(for: "alice")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no oauth token found"))
            XCTAssertTrue(error.localizedDescription.contains("gh auth login"))
        }

        let missing = ScriptedProcessRunner { _ in output("") }
        do {
            _ = try await cli(missing, installed: false).accounts()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? GitHubCLIError, .notInstalled)
            XCTAssertTrue(missing.requests.isEmpty)
        }

        let garbage = ScriptedProcessRunner { _ in output("not json") }
        do {
            _ = try await cli(garbage).accounts()
            XCTFail("Expected an error")
        } catch {
            guard case .listFailed = error as? GitHubCLIError else { return XCTFail("Got \(error)") }
        }
    }

    func testTokenShape() {
        XCTAssertTrue(GitHubCLI.looksLikeToken(aliceToken))
        XCTAssertTrue(GitHubCLI.looksLikeToken("github_pat_11ABCDEFG0123456789_abcdefghijklmnop"))
        XCTAssertFalse(GitHubCLI.looksLikeToken("short"))
        XCTAssertFalse(GitHubCLI.looksLikeToken("gho_token with spaces 0000000"))
        XCTAssertFalse(GitHubCLI.looksLikeToken("gho_token\n0000000000000000000"))
    }
}

final class GitHubCLIAccountTests: XCTestCase {
    private var directory: URL!
    private var transport: MockHTTPTransport!
    private var credentials: InMemoryCredentialStore!
    private var accountStore: GitHubAccountStore!
    private var clock: MutableClock!
    private var runner: ScriptedProcessRunner!
    private var service: GitHubAuthService!
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")
    private let alice = AccountID(host: "github.com", userID: 100)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-cli-\(UUID().uuidString)")
        transport = MockHTTPTransport()
        transport.json(path: "/user", token: aliceToken, GitHubFixtures.user(id: 100, login: "alice"))
        transport.json(path: "/user", token: aliceTokenRotated, GitHubFixtures.user(id: 100, login: "alice"))
        transport.json(path: "/user", token: mallory, GitHubFixtures.user(id: 666, login: "mallory"))
        transport.json(path: "/user", token: "ghu_alice", GitHubFixtures.user(id: 100, login: "alice"))
        credentials = InMemoryCredentialStore()
        accountStore = GitHubAccountStore(store: JSONFileStore(directory: AppDataDirectory(url: directory), fileName: "accounts.json"))
        clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        runner = ScriptedProcessRunner { request in
            request.arguments.contains("token") ? output(aliceToken + "\n") : output(statusJSON)
        }
        let clock = self.clock!
        let api = GitHubAPIClient(transport: transport, configuration: configuration, now: { clock.now })
        service = GitHubAuthService(
            configuration: configuration,
            deviceFlow: GitHubDeviceFlow(transport: transport, configuration: configuration, sleeper: RecordingSleeper(), now: { clock.now }),
            api: api,
            accounts: accountStore,
            credentials: credentials,
            gitHubCLI: GitHubCLI(runner: runner, candidates: ["/opt/homebrew/bin/gh"], isExecutable: { _ in true }, baseEnvironment: [:]),
            now: { clock.now }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var tokenRequests: Int { runner.requests.filter { $0.arguments.contains("token") }.count }

    func testConnectVerifiesIdentityAndStoresNoToken() async throws {
        let result = try await service.connectGitHubCLI(login: "alice")
        guard case .added(let account) = result else { return XCTFail("Expected added") }
        XCTAssertEqual(account.id, alice)
        XCTAssertEqual(account.source, .gitHubCLI)
        XCTAssertEqual(account.state, .connected)
        XCTAssertNil(try credentials.load(for: alice), "A GitHub CLI account has no WCleaner Keychain item")

        let data = try Data(contentsOf: directory.appendingPathComponent("accounts.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("gho_"), "Tokens never reach the metadata file")
    }

    func testTokenIsReusedBrieflyThenFetchedAndReverified() async throws {
        _ = try await service.connectGitHubCLI(login: "alice")
        XCTAssertEqual(tokenRequests, 1)
        let first = try await service.accessToken(for: alice)
        XCTAssertEqual(first, aliceToken)
        XCTAssertEqual(tokenRequests, 1, "Reused from memory within its lifetime")

        clock.advance(GitHubAuthService.cliTokenLifetime + 1)
        runner.setResponder { _ in output(aliceTokenRotated) }
        let second = try await service.accessToken(for: alice)
        XCTAssertEqual(second, aliceTokenRotated)
        XCTAssertEqual(tokenRequests, 2)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/user" }.count, 2, "Each fresh token is checked against GET /user")
    }

    func testTokenForAnotherUserMarksTheAccountForReconnect() async throws {
        _ = try await service.connectGitHubCLI(login: "alice")
        clock.advance(GitHubAuthService.cliTokenLifetime + 1)
        runner.setResponder { _ in output(mallory) }
        do {
            _ = try await service.accessToken(for: alice)
            XCTFail("Expected an error")
        } catch {
            guard case .needsReconnect = error as? GitHubAuthError else { return XCTFail("Got \(error)") }
        }
        let state = await accountStore.account(alice)?.state
        XCTAssertEqual(state, .needsReconnect(reason: "GitHub CLI now returns a token for @mallory."))
    }

    func testLoggedOutGitHubCLIMarksTheAccountForReconnect() async throws {
        _ = try await service.connectGitHubCLI(login: "alice")
        clock.advance(GitHubAuthService.cliTokenLifetime + 1)
        runner.setResponder { _ in output("", exit: 1, stderr: "no oauth token found for github.com account alice") }
        do {
            _ = try await service.accessToken(for: alice)
            XCTFail("Expected an error")
        } catch {}
        let state = await accountStore.account(alice)?.state
        guard case .needsReconnect(let reason) = state else { return XCTFail("Got \(String(describing: state))") }
        XCTAssertTrue(reason.contains("gh auth login"))
    }

    func testLoginMismatchIsRejectedAndNothingIsSaved() async {
        runner.setResponder { _ in output(mallory) }
        do {
            _ = try await service.connectGitHubCLI(login: "alice")
            XCTFail("Expected an error")
        } catch {
            guard case .verificationFailed = error as? GitHubAuthError else { return XCTFail("Got \(error)") }
        }
        let all = await accountStore.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testSwitchingADeviceFlowAccountDeletesItsKeychainItems() async throws {
        _ = try await service.register(
            token: OAuthToken(accessToken: "ghu_alice", scope: nil, expiresAt: nil, refreshToken: "ghr_alice", refreshTokenExpiresAt: nil),
            expecting: nil
        )
        XCTAssertNotNil(try credentials.load(for: alice))
        let result = try await service.connectGitHubCLI(login: "alice", expecting: alice)
        guard case .updated(let account) = result else { return XCTFail("Expected updated") }
        XCTAssertEqual(account.source, .gitHubCLI)
        XCTAssertNil(try credentials.load(for: alice), "The unused device-flow tokens are removed")
        let all = await accountStore.all()
        XCTAssertEqual(all.count, 1)
    }

    func testDisconnectLeavesGitHubCLIAlone() async throws {
        _ = try await service.connectGitHubCLI(login: "alice")
        let before = runner.requests.count
        try await service.disconnect(alice)
        let remaining = await accountStore.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(runner.requests.count, before, "Disconnecting never runs gh (no logout)")
        XCTAssertFalse(runner.requests.contains { $0.arguments.contains("logout") })
    }

    func testAccountsSavedBeforeSourcesExistedAreDeviceFlow() throws {
        let json = """
        [{"id":{"host":"github.com","userID":5},"login":"old","addedAt":0,"lastVerifiedAt":0,"hasRefreshToken":true,"state":{"connected":{}}}]
        """
        let accounts = try JSONDecoder().decode([GitHubAccount].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.first?.source, .deviceFlow)
        let roundTrip = try JSONDecoder().decode([GitHubAccount].self, from: JSONEncoder().encode(accounts))
        XCTAssertEqual(roundTrip, accounts)
    }
}
