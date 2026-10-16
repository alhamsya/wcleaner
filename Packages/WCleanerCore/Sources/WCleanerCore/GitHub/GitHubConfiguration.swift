import Foundation

/// Public configuration for GitHub.com. Contains no secrets: WCleaner uses a public client ID with the
/// OAuth device flow and never embeds a client secret or GitHub App private key.
public struct GitHubConfiguration: Sendable, Equatable {
    public var host: String
    public var apiBaseURL: URL
    public var webBaseURL: URL
    public var clientID: String?
    public var userAgent: String

    public init(
        host: String = "github.com",
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        webBaseURL: URL = URL(string: "https://github.com")!,
        clientID: String?,
        userAgent: String = "WCleaner"
    ) {
        self.host = host
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
        self.clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = userAgent
    }

    /// True when a plausible client ID is present. Build settings that were never substituted
    /// (for example a literal `$(WCLEANER_GITHUB_CLIENT_ID)`) count as missing.
    public var isConfigured: Bool { validClientID != nil }

    public var validClientID: String? {
        guard let clientID, !clientID.isEmpty, clientID.count <= 64,
              clientID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") })
        else { return nil }
        return clientID
    }

    /// GitHub App client IDs start with `Iv`; they use the app's fine-grained permissions and ignore scopes.
    /// OAuth Apps need the `repo` scope to read pull requests of private repositories.
    public var isGitHubApp: Bool { validClientID?.hasPrefix("Iv") ?? false }

    public var requestedScope: String? { isGitHubApp ? nil : "repo" }

    public var deviceCodeURL: URL { webBaseURL.appendingPathComponent("login/device/code") }
    public var accessTokenURL: URL { webBaseURL.appendingPathComponent("login/oauth/access_token") }

    /// Remote hosts that refer to this GitHub instance.
    public func matchesRemoteHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == self.host || lowered == "www.\(self.host)" || lowered == "ssh.\(self.host)"
    }
}
