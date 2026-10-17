import Foundation

/// An account that GitHub CLI (`gh`) is logged in to.
public struct GitHubCLIAccount: Sendable, Equatable {
    public var login: String
    public var isActive: Bool
    /// False when `gh` reports a problem with the stored token (for example it was revoked).
    public var isUsable: Bool
    public var scopes: [String]

    public init(login: String, isActive: Bool, isUsable: Bool, scopes: [String]) {
        self.login = login
        self.isActive = isActive
        self.isUsable = isUsable
        self.scopes = scopes
    }
}

public enum GitHubCLIError: Error, Sendable, Equatable, LocalizedError {
    case notInstalled
    case listFailed(String)
    case tokenUnavailable(login: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "GitHub CLI (gh) was not found in /opt/homebrew/bin or /usr/local/bin. Install it with “brew install gh” and log in with “gh auth login”."
        case .listFailed(let detail):
            "GitHub CLI could not list its accounts: \(detail)"
        case .tokenUnavailable(let login, let detail):
            "GitHub CLI has no usable token for @\(login): \(detail) Log in again with “gh auth login”."
        }
    }
}

/// Reads accounts and tokens from an installed GitHub CLI. WCleaner never stores these tokens: it asks
/// `gh` for one when it needs it, and `gh` keeps it in its own macOS Keychain item.
/// Every call uses discrete arguments, an allow-listed environment (no `GH_TOKEN`, `GITHUB_TOKEN` or
/// `GH_HOST` from the app's environment) and a timeout.
public struct GitHubCLI: Sendable {
    public static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    private let runner: any ProcessRunning
    private let candidates: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let host: String
    private let baseEnvironment: [String: String]

    public init(
        host: String = "github.com",
        runner: any ProcessRunning = SubprocessRunner(),
        candidates: [String] = candidatePaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.host = host
        self.runner = runner
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.baseEnvironment = baseEnvironment
    }

    public var executablePath: String? {
        candidates.first(where: isExecutable)
    }

    /// The accounts `gh` is logged in to on this host (`gh auth status --json hosts`; no tokens are printed).
    public func accounts() async throws -> [GitHubCLIAccount] {
        let result = try await run(["auth", "status", "--hostname", host, "--json", "hosts"], timeout: .seconds(20))
        // With --json, gh exits 0 even when an account has a problem; anything else means it failed.
        guard result.succeeded else {
            throw GitHubCLIError.listFailed(Self.firstLine(result.stderrString) ?? "exit status \(result.exitCode)")
        }
        return try Self.parseAccounts(result.stdout, host: host)
    }

    /// A token for exactly this login (`gh auth token --hostname <host> --user <login>`).
    /// The token never appears in errors or logs.
    public func token(for login: String) async throws -> String {
        let result = try await run(["auth", "token", "--hostname", host, "--user", login], timeout: .seconds(10))
        guard result.succeeded else {
            throw GitHubCLIError.tokenUnavailable(login: login, detail: Self.firstLine(result.stderrString) ?? "exit status \(result.exitCode).")
        }
        let token = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(token) else {
            throw GitHubCLIError.tokenUnavailable(login: login, detail: "it returned something that is not a token.")
        }
        return token
    }

    static func parseAccounts(_ data: Data, host: String) throws -> [GitHubCLIAccount] {
        struct Entry: Decodable {
            var login: String
            var active: Bool?
            var state: String?
            var scopes: String?
        }
        struct Status: Decodable {
            var hosts: [String: [Entry]]
        }
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw GitHubCLIError.listFailed("Its output was not understood. Update GitHub CLI with “brew upgrade gh”.")
        }
        let entries = status.hosts.first { $0.key.lowercased() == host.lowercased() }?.value ?? []
        return entries.map { entry in
            GitHubCLIAccount(
                login: entry.login,
                isActive: entry.active ?? false,
                isUsable: entry.state == "success",
                scopes: (entry.scopes ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    static func looksLikeToken(_ value: String) -> Bool {
        (20...512).contains(value.count) && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }
    }

    /// Only what `gh` needs to find its configuration and the login Keychain.
    static func environment(from base: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = base[key] { environment[key] = value }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["LC_ALL"] = "C"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        return environment
    }

    private func run(_ arguments: [String], timeout: Duration) async throws -> ProcessResult {
        guard let path = executablePath else { throw GitHubCLIError.notInstalled }
        return try await runner.run(ProcessRequest(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            environment: Self.environment(from: baseEnvironment),
            timeout: timeout,
            maxOutputBytes: 256 * 1024
        ))
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(200))
    }
}
