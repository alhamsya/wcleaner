import Foundation

/// What the user needs to authorize a device: a code to type at `verificationURI`.
public struct DeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresAt: Date
    public let interval: Int

    public init(deviceCode: String, userCode: String, verificationURI: URL, expiresAt: Date, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

/// A user access token. Its descriptions are redacted so it can never be logged by accident.
public struct OAuthToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let scope: String?
    public let expiresAt: Date?
    public let refreshToken: String?
    public let refreshTokenExpiresAt: Date?

    public init(accessToken: String, scope: String?, expiresAt: Date?, refreshToken: String?, refreshTokenExpiresAt: Date?) {
        self.accessToken = accessToken
        self.scope = scope
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public var description: String {
        "OAuthToken(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "none" : "<redacted>"), expiresAt: \(expiresAt.map { "\($0)" } ?? "never"))"
    }

    public var debugDescription: String { description }
}

public enum DeviceFlowError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case expired
    case accessDenied
    case deviceFlowDisabled
    case incorrectClient
    case refreshRejected(String)
    case unexpected(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "GitHub sign-in is not configured: this build has no GitHub client ID."
        case .expired: "The sign-in code expired. Start again."
        case .accessDenied: "Authorization was denied on GitHub."
        case .deviceFlowDisabled: "Device flow is not enabled for the configured GitHub App or OAuth App."
        case .incorrectClient: "GitHub did not recognise the configured client ID."
        case .refreshRejected(let detail): "GitHub did not renew the token: \(detail)"
        case .unexpected(let detail): "GitHub sign-in failed: \(detail)"
        case .network(let detail): "Network error during sign-in: \(detail)"
        }
    }
}

/// OAuth 2.0 device authorization grant against github.com. Public client: client ID only, no secret.
public struct GitHubDeviceFlow: Sendable {
    private struct DeviceCodeDTO: Decodable {
        let deviceCode: String?
        let userCode: String?
        let verificationUri: String?
        let expiresIn: Int?
        let interval: Int?
        let error: String?
        let errorDescription: String?
    }

    private struct TokenDTO: Decodable {
        let accessToken: String?
        let scope: String?
        let expiresIn: Int?
        let refreshToken: String?
        let refreshTokenExpiresIn: Int?
        let error: String?
        let errorDescription: String?
        let interval: Int?
    }

    private let transport: any HTTPTransport
    private let configuration: GitHubConfiguration
    private let sleeper: any Sleeper
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        configuration: GitHubConfiguration,
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.configuration = configuration
        self.sleeper = sleeper
        self.now = now
    }

    public func start() async throws -> DeviceAuthorization {
        guard let clientID = configuration.validClientID else { throw DeviceFlowError.notConfigured }
        var fields = [("client_id", clientID)]
        if let scope = configuration.requestedScope {
            fields.append(("scope", scope))
        }
        let dto: DeviceCodeDTO = try await post(configuration.deviceCodeURL, fields: fields)
        if let error = dto.error {
            throw Self.map(error: error, description: dto.errorDescription)
        }
        guard let deviceCode = dto.deviceCode, let userCode = dto.userCode,
              let uriString = dto.verificationUri, let uri = URL(string: uriString), uri.scheme == "https",
              let expiresIn = dto.expiresIn else {
            throw DeviceFlowError.unexpected("Incomplete device code response.")
        }
        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            interval: max(5, dto.interval ?? 5)
        )
    }

    /// Polls until the user authorizes, denies, or the code expires. Cancellable.
    public func poll(_ authorization: DeviceAuthorization) async throws -> OAuthToken {
        guard let clientID = configuration.validClientID else { throw DeviceFlowError.notConfigured }
        var interval = max(5, authorization.interval)
        while true {
            try Task.checkCancellation()
            if now() >= authorization.expiresAt {
                throw DeviceFlowError.expired
            }
            try await sleeper.sleep(for: .seconds(interval))
            let dto: TokenDTO = try await post(configuration.accessTokenURL, fields: [
                ("client_id", clientID),
                ("device_code", authorization.deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            if let token = makeToken(dto) {
                return token
            }
            switch dto.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = max(interval + 5, dto.interval ?? 0)
            case let error?:
                throw Self.map(error: error, description: dto.errorDescription)
            case nil:
                throw DeviceFlowError.unexpected("No token in response.")
            }
        }
    }

    /// Renews an expiring GitHub App user token with its refresh token (client ID only, no secret).
    public func refresh(refreshToken: String) async throws -> OAuthToken {
        guard let clientID = configuration.validClientID else { throw DeviceFlowError.notConfigured }
        let dto: TokenDTO = try await post(configuration.accessTokenURL, fields: [
            ("client_id", clientID),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
        if let token = makeToken(dto) {
            return token
        }
        throw DeviceFlowError.refreshRejected(dto.error ?? "No token in response.")
    }

    private func makeToken(_ dto: TokenDTO) -> OAuthToken? {
        guard let accessToken = dto.accessToken, !accessToken.isEmpty else { return nil }
        let issued = now()
        return OAuthToken(
            accessToken: accessToken,
            scope: dto.scope,
            expiresAt: dto.expiresIn.map { issued.addingTimeInterval(TimeInterval($0)) },
            refreshToken: dto.refreshToken.flatMap { $0.isEmpty ? nil : $0 },
            refreshTokenExpiresAt: dto.refreshTokenExpiresIn.map { issued.addingTimeInterval(TimeInterval($0)) }
        )
    }

    private static func map(error: String, description: String?) -> DeviceFlowError {
        switch error {
        case "expired_token": .expired
        case "access_denied": .accessDenied
        case "device_flow_disabled": .deviceFlowDisabled
        case "incorrect_client_credentials", "unauthorized_client": .incorrectClient
        default: .unexpected(description ?? error)
        }
    }

    private func post<T: Decodable>(_ url: URL, fields: [(String, String)]) async throws -> T {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeviceFlowError.network(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 400 || response.statusCode == 401 else {
            throw DeviceFlowError.unexpected("HTTP \(response.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DeviceFlowError.unexpected("Unreadable response (HTTP \(response.statusCode)).")
        }
    }
}
