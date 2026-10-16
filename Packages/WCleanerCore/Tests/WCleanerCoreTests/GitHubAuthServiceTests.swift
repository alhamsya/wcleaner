import XCTest
@testable import WCleanerCore

final class GitHubAuthServiceTests: XCTestCase {
    private var directory: URL!
    private var transport: MockHTTPTransport!
    private var credentials: InMemoryCredentialStore!
    private var accountStore: GitHubAccountStore!
    private var clock: MutableClock!
    private var service: GitHubAuthService!
    private let configuration = GitHubConfiguration(clientID: "Iv23liTEST")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WCleanerTests-auth-\(UUID().uuidString)")
        transport = MockHTTPTransport()
        transport.json(path: "/user", token: "ghu_alice", GitHubFixtures.user(id: 100, login: "alice"))
        transport.json(path: "/user", token: "ghu_alice2", GitHubFixtures.user(id: 100, login: "alice-renamed"))
        transport.json(path: "/user", token: "ghu_bob", GitHubFixtures.user(id: 200, login: "bob"))
        transport.json(path: "/user", token: "ghu_bad", status: 401, "{}")
        credentials = InMemoryCredentialStore()
        accountStore = GitHubAccountStore(store: JSONFileStore(directory: AppDataDirectory(url: directory), fileName: "accounts.json"))
        clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let clock = self.clock!
        let api = GitHubAPIClient(transport: transport, configuration: configuration, now: { clock.now })
        service = GitHubAuthService(
            configuration: configuration,
            deviceFlow: GitHubDeviceFlow(transport: transport, configuration: configuration, sleeper: RecordingSleeper(), now: { clock.now }),
            api: api,
            accounts: accountStore,
            credentials: credentials,
            now: { clock.now }
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func token(_ access: String, refresh: String? = nil, expiresIn: TimeInterval? = nil) -> OAuthToken {
        OAuthToken(
            accessToken: access,
            scope: nil,
            expiresAt: expiresIn.map { clock.now.addingTimeInterval($0) },
            refreshToken: refresh,
            refreshTokenExpiresAt: refresh == nil ? nil : clock.now.addingTimeInterval(86_400 * 30)
        )
    }

    func testSignInIsKeyedByImmutableUserID() async throws {
        let result = try await service.register(token: token("ghu_alice"), expecting: nil)
        guard case .added(let account) = result else { return XCTFail("Expected added") }
        XCTAssertEqual(account.id, AccountID(host: "github.com", userID: 100))
        XCTAssertEqual(account.login, "alice")
        XCTAssertEqual(account.state, .connected)
        XCTAssertEqual(try credentials.load(for: account.id)?.accessToken, "ghu_alice")
    }

    func testRepeatedSignInToSameAccountIsDeduplicated() async throws {
        _ = try await service.register(token: token("ghu_alice"), expecting: nil)
        clock.advance(60)
        let second = try await service.register(token: token("ghu_alice2"), expecting: nil)
        guard case .updated(let account) = second else { return XCTFail("Expected updated") }
        XCTAssertEqual(account.login, "alice-renamed", "Login changes are picked up; identity stays the user ID")
        let all = await accountStore.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].addedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try credentials.load(for: account.id)?.accessToken, "ghu_alice2")
    }

    func testMultipleAccountsCoexistAndDisconnectIsIsolated() async throws {
        let alice = try await service.register(token: token("ghu_alice"), expecting: nil).account
        let bob = try await service.register(token: token("ghu_bob"), expecting: nil).account
        let count = await accountStore.all().count
        XCTAssertEqual(count, 2)

        try await service.disconnect(alice.id)
        let remaining = await accountStore.all()
        XCTAssertEqual(remaining.map(\.id), [bob.id])
        XCTAssertNil(try credentials.load(for: alice.id))
        XCTAssertEqual(try credentials.load(for: bob.id)?.accessToken, "ghu_bob")
        let bobToken = try await service.accessToken(for: bob.id)
        XCTAssertEqual(bobToken, "ghu_bob")
    }

    func testReconnectRejectsADifferentUserAndStoresNothing() async throws {
        let alice = try await service.register(token: token("ghu_alice"), expecting: nil).account
        do {
            _ = try await service.register(token: token("ghu_bob"), expecting: alice.id)
            XCTFail("Expected differentAccount")
        } catch let error as GitHubAuthError {
            XCTAssertEqual(error, .differentAccount(expected: "alice", actual: "bob"))
        }
        XCTAssertNil(try credentials.load(for: AccountID(host: "github.com", userID: 200)))
        let count = await accountStore.all().count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try credentials.load(for: alice.id)?.accessToken, "ghu_alice")
    }

    func testUnverifiedTokenIsNeverStored() async {
        do {
            _ = try await service.register(token: token("ghu_bad"), expecting: nil)
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertTrue(error is GitHubAuthError)
        }
        XCTAssertTrue(credentials.storedAccounts.isEmpty)
        let count = await accountStore.all().count
        XCTAssertEqual(count, 0)
    }

    func testKeychainFailurePreventsAccountCreation() async {
        credentials.failSaves = true
        await XCTAssertThrowsErrorAsync(try await self.service.register(token: self.token("ghu_alice"), expecting: nil))
        let count = await accountStore.all().count
        XCTAssertEqual(count, 0)
    }

    func testExpiringTokenIsRefreshedWithoutSecret() async throws {
        transport.json(path: "/login/oauth/access_token", #"{"access_token":"ghu_refreshed","expires_in":28800,"refresh_token":"ghr_next","refresh_token_expires_in":15897600}"#)
        let alice = try await service.register(token: token("ghu_alice", refresh: "ghr_first", expiresIn: 28_800), expecting: nil).account

        let beforeExpiry = try await service.accessToken(for: alice.id)
        XCTAssertEqual(beforeExpiry, "ghu_alice")

        clock.advance(28_800)
        let refreshed = try await service.accessToken(for: alice.id)
        XCTAssertEqual(refreshed, "ghu_refreshed")
        XCTAssertEqual(try credentials.load(for: alice.id), StoredCredentials(accessToken: "ghu_refreshed", refreshToken: "ghr_next"))
        let refreshRequest = try XCTUnwrap(transport.requests.last { $0.url?.path == "/login/oauth/access_token" })
        let body = String(decoding: refreshRequest.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testFailedRefreshMarksOnlyThatAccountForReconnect() async throws {
        transport.json(path: "/login/oauth/access_token", #"{"error":"bad_refresh_token"}"#)
        let alice = try await service.register(token: token("ghu_alice", refresh: "ghr_first", expiresIn: 60), expecting: nil).account
        let bob = try await service.register(token: token("ghu_bob"), expecting: nil).account
        clock.advance(3600)
        await XCTAssertThrowsErrorAsync(try await self.service.accessToken(for: alice.id))
        let aliceState = await accountStore.account(alice.id)?.state
        XCTAssertEqual(aliceState, .needsReconnect(reason: "Its token expired and could not be renewed."))
        let bobToken = try await service.accessToken(for: bob.id)
        XCTAssertEqual(bobToken, "ghu_bob")
    }

    func testAccountMetadataOnDiskNeverContainsTokens() async throws {
        _ = try await service.register(token: token("ghu_alice", refresh: "ghr_secret_refresh", expiresIn: 3600), expecting: nil)
        let data = try Data(contentsOf: directory.appendingPathComponent("accounts.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("alice"))
        XCTAssertFalse(text.contains("ghu_alice"))
        XCTAssertFalse(text.contains("ghr_secret_refresh"))
        XCTAssertFalse(String(describing: StoredCredentials(accessToken: "ghu_x", refreshToken: "ghr_y")).contains("ghu_x"))
    }
}

/// Real Keychain round trip. Opt-in because it touches the login Keychain:
/// `WCLEANER_KEYCHAIN_TESTS=1 swift test --filter KeychainCredentialStoreTests`
final class KeychainCredentialStoreTests: XCTestCase {
    func testRoundTripAndIsolationInRealKeychain() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WCLEANER_KEYCHAIN_TESTS"] == "1", "Set WCLEANER_KEYCHAIN_TESTS=1 to run")
        let store = KeychainCredentialStore(serviceBase: "io.github.alhamsya.WCleaner.tests.\(UUID().uuidString)")
        let alice = AccountID(host: "github.com", userID: 1)
        let bob = AccountID(host: "github.com", userID: 2)
        defer {
            try? store.delete(for: alice)
            try? store.delete(for: bob)
        }
        try store.save(StoredCredentials(accessToken: "ghu_a", refreshToken: "ghr_a"), for: alice)
        try store.save(StoredCredentials(accessToken: "ghu_b", refreshToken: nil), for: bob)
        XCTAssertEqual(try store.load(for: alice), StoredCredentials(accessToken: "ghu_a", refreshToken: "ghr_a"))
        XCTAssertEqual(try store.load(for: bob), StoredCredentials(accessToken: "ghu_b", refreshToken: nil))

        try store.save(StoredCredentials(accessToken: "ghu_a2", refreshToken: nil), for: alice)
        XCTAssertEqual(try store.load(for: alice), StoredCredentials(accessToken: "ghu_a2", refreshToken: nil), "Updating removes a stale refresh token")

        try store.delete(for: alice)
        XCTAssertNil(try store.load(for: alice))
        XCTAssertEqual(try store.load(for: bob)?.accessToken, "ghu_b")
    }
}
