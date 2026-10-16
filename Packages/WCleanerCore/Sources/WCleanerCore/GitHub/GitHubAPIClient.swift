import Foundation

public enum GitHubAPIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized
    case forbidden(String)
    case notFound
    case unprocessable(String)
    case rateLimited(resetAt: Date?)
    case server(Int)
    case unexpectedStatus(Int)
    case network(String)
    case decoding(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token (401). Reconnect the account."
        case .forbidden(let message): "GitHub denied access (403)\(message.isEmpty ? "" : ": \(message)")."
        case .notFound: "Not found on GitHub, or the account has no access (404)."
        case .unprocessable(let message): "GitHub could not process the request (422)\(message.isEmpty ? "" : ": \(message)")."
        case .rateLimited(let resetAt):
            resetAt.map { "GitHub rate limit reached; resets at \(EnglishDateFormat.time.format($0))." } ?? "GitHub rate limit reached."
        case .server(let status): "GitHub had a server error (\(status))."
        case .unexpectedStatus(let status): "Unexpected response from GitHub (\(status))."
        case .network(let message): "Network error: \(message)"
        case .decoding(let message): "Unexpected data from GitHub: \(message)"
        case .invalidRequest(let message): "Invalid request: \(message)"
        }
    }

    /// Temporary failures where retrying later may succeed.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network: true
        default: false
        }
    }
}

/// Minimal GitHub REST client. Tokens are passed per call and never stored or logged here.
/// Keeps an in-memory ETag cache (304 responses don't count against the rate limit) and tracks
/// rate limits separately for every account.
public actor GitHubAPIClient {
    public enum CachePolicy: Sendable {
        /// Send `If-None-Match` and reuse the cached body on 304.
        case revalidate
        /// Always fetch a fresh body (used for evidence immediately before removal).
        case fresh
    }

    private struct CachedBody {
        let etag: String
        let data: Data
    }

    private let transport: any HTTPTransport
    private let configuration: GitHubConfiguration
    private let now: @Sendable () -> Date
    private let maxCacheEntries: Int
    private var cache: [String: CachedBody] = [:]
    private var cacheOrder: [String] = []
    private var rateLimitedUntil: [AccountID: Date] = [:]
    private(set) var requestCount = 0

    public init(
        transport: any HTTPTransport,
        configuration: GitHubConfiguration,
        maxCacheEntries: Int = 256,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.configuration = configuration
        self.maxCacheEntries = maxCacheEntries
        self.now = now
    }

    public func rateLimitReset(for account: AccountID) -> Date? {
        guard let until = rateLimitedUntil[account], until > now() else { return nil }
        return until
    }

    // MARK: Endpoints

    public func currentUser(token: String, account: AccountID? = nil) async throws -> GitHubUserDTO {
        try await get(GitHubUserDTO.self, path: ["user"], token: token, account: account, cachePolicy: .fresh)
    }

    public func repository(_ ref: HostedRepositoryRef, token: String, account: AccountID, cachePolicy: CachePolicy = .revalidate) async throws -> GitHubRepositoryDTO {
        try validate(ref)
        return try await get(GitHubRepositoryDTO.self, path: ["repos", ref.owner, ref.name], token: token, account: account, cachePolicy: cachePolicy)
    }

    /// `GET /repos/{owner}/{repo}/pulls?state=all&head=<headOwner>:<branch>`
    public func pullRequests(
        base: HostedRepositoryRef,
        headOwner: String,
        headBranch: String,
        token: String,
        account: AccountID
    ) async throws -> [GitHubPullRequestDTO] {
        try validate(base)
        guard RemoteURLParser.isValidSegment(headOwner), !headBranch.isEmpty else {
            throw GitHubAPIError.invalidRequest("Invalid head reference.")
        }
        return try await get(
            [GitHubPullRequestDTO].self,
            path: ["repos", base.owner, base.name, "pulls"],
            query: [("state", "all"), ("head", "\(headOwner):\(headBranch)"), ("per_page", "100")],
            token: token,
            account: account,
            cachePolicy: .revalidate
        )
    }

    /// `GET /repos/{owner}/{repo}/commits/{sha}/pulls`. Unknown commits (404/422) mean "no pull requests".
    public func pullRequests(base: HostedRepositoryRef, commit sha: String, token: String, account: AccountID) async throws -> [GitHubPullRequestDTO] {
        try validate(base)
        guard GitObjectID.isValid(sha) else { throw GitHubAPIError.invalidRequest("Invalid commit SHA.") }
        do {
            return try await get(
                [GitHubPullRequestDTO].self,
                path: ["repos", base.owner, base.name, "commits", sha, "pulls"],
                query: [("per_page", "100")],
                token: token,
                account: account,
                cachePolicy: .revalidate
            )
        } catch GitHubAPIError.notFound, GitHubAPIError.unprocessable {
            return []
        }
    }

    public func pullRequest(base: HostedRepositoryRef, number: Int, token: String, account: AccountID, cachePolicy: CachePolicy) async throws -> GitHubPullRequestDTO {
        try validate(base)
        guard number > 0 else { throw GitHubAPIError.invalidRequest("Invalid pull request number.") }
        return try await get(
            GitHubPullRequestDTO.self,
            path: ["repos", base.owner, base.name, "pulls", String(number)],
            token: token,
            account: account,
            cachePolicy: cachePolicy
        )
    }

    // MARK: Core request

    public func get<T: Decodable & Sendable>(
        _ type: T.Type,
        path: [String],
        query: [(String, String)] = [],
        token: String,
        account: AccountID?,
        cachePolicy: CachePolicy
    ) async throws -> T {
        if let account, let until = rateLimitedUntil[account] {
            if until > now() {
                throw GitHubAPIError.rateLimited(resetAt: until)
            }
            rateLimitedUntil[account] = nil
        }

        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let cacheKey = "\(account?.storageKey ?? "anonymous") \(url.absoluteString)"
        let cached = cachePolicy == .revalidate ? cache[cacheKey] : nil
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            requestCount += 1
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubAPIError.network(error.localizedDescription)
        }

        let body: Data
        switch response.statusCode {
        case 200:
            body = data
            if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                store(cacheKey, CachedBody(etag: etag, data: data))
            }
        case 304:
            guard let cached else { throw GitHubAPIError.unexpectedStatus(304) }
            body = cached.data
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            if let reset = rateLimitReset(from: response) {
                if let account { rateLimitedUntil[account] = reset }
                throw GitHubAPIError.rateLimited(resetAt: reset)
            }
            if response.statusCode == 429 {
                throw GitHubAPIError.rateLimited(resetAt: nil)
            }
            throw GitHubAPIError.forbidden(errorMessage(data))
        case 404:
            throw GitHubAPIError.notFound
        case 422:
            throw GitHubAPIError.unprocessable(errorMessage(data))
        case 500...599:
            throw GitHubAPIError.server(response.statusCode)
        default:
            throw GitHubAPIError.unexpectedStatus(response.statusCode)
        }

        do {
            return try Self.decoder.decode(T.self, from: body)
        } catch {
            throw GitHubAPIError.decoding(String(describing: error).prefix(200).description)
        }
    }

    // MARK: Helpers

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func validate(_ ref: HostedRepositoryRef) throws {
        guard ref.host == configuration.host,
              RemoteURLParser.isValidSegment(ref.owner),
              RemoteURLParser.isValidSegment(ref.name) else {
            throw GitHubAPIError.invalidRequest("Invalid repository \(ref).")
        }
    }

    private func makeURL(path: [String], query: [(String, String)]) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var string = configuration.apiBaseURL.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        for segment in path {
            guard !segment.isEmpty, segment != ".", segment != "..",
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw GitHubAPIError.invalidRequest("Invalid path segment.")
            }
            string += "/" + encoded
        }
        if !query.isEmpty {
            let pairs = query.compactMap { name, value -> String? in
                guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed),
                      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                return "\(encodedName)=\(encodedValue)"
            }
            string += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: string) else {
            throw GitHubAPIError.invalidRequest("Could not build URL.")
        }
        return url
    }

    private func rateLimitReset(from response: HTTPURLResponse) -> Date? {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(retryAfter) {
            return now().addingTimeInterval(max(1, seconds))
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let epoch = TimeInterval(reset) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    private func errorMessage(_ data: Data) -> String {
        let message = (try? JSONDecoder().decode(GitHubErrorDTO.self, from: data))?.message ?? ""
        return String(message.prefix(200))
    }

    private func store(_ key: String, _ body: CachedBody) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = body
        while cacheOrder.count > maxCacheEntries {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    /// Drops cached bodies, e.g. after an account is disconnected.
    public func clearCache(for account: AccountID? = nil) {
        guard let account else {
            cache.removeAll()
            cacheOrder.removeAll()
            return
        }
        let prefix = account.storageKey + " "
        cacheOrder.removeAll { $0.hasPrefix(prefix) }
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        rateLimitedUntil[account] = nil
    }
}
