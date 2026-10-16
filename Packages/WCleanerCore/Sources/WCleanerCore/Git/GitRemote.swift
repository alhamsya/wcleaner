import Foundation

/// A configured Git remote. The URL is sanitized: any embedded credentials are stripped on parse.
public struct GitRemote: Sendable, Equatable, Hashable, Codable {
    public let name: String
    public let url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = RemoteURLParser.redactingCredentials(url)
    }

    /// Parses `git config --null --get-regexp '^remote\..*\.url$'` output (`key\nvalue\0`).
    static func parseConfigOutput(_ data: Data) -> [GitRemote] {
        var remotes: [GitRemote] = []
        for entry in data.split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let newline = text.firstIndex(of: "\n") else { continue }
            let key = text[..<newline]
            let value = String(text[text.index(after: newline)...])
            guard key.hasPrefix("remote."), key.hasSuffix(".url") else { continue }
            let name = String(key.dropFirst("remote.".count).dropLast(".url".count))
            guard !name.isEmpty else { continue }
            remotes.append(GitRemote(name: name, url: value))
        }
        return remotes
    }
}

/// `owner/name` on a hosting service.
public struct HostedRepositoryRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public let host: String
    public let owner: String
    public let name: String

    public init(host: String, owner: String, name: String) {
        self.host = host.lowercased()
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { "\(host)/\(fullName)" }

    /// Case-insensitive comparison, matching GitHub's owner/name semantics.
    public func matches(_ other: HostedRepositoryRef) -> Bool {
        host == other.host && owner.lowercased() == other.owner.lowercased() && name.lowercased() == other.name.lowercased()
    }
}

public enum RemoteURLParser {
    /// Parses HTTPS, SSH (scp-like and ssh://) and git:// remote URLs into host/owner/name.
    /// Returns nil for anything that is not exactly `owner/name` on a host.
    public static func parse(_ rawURL: String) -> HostedRepositoryRef? {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        let host: String
        let path: String

        if url.contains("://") {
            guard let components = URLComponents(string: url),
                  let scheme = components.scheme?.lowercased(),
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let parsedHost = components.host, !parsedHost.isEmpty else { return nil }
            host = parsedHost
            path = components.path
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            // scp-like syntax: [user@]host:owner/name.git
            var hostPart = String(url[..<colon])
            if let at = hostPart.lastIndex(of: "@") {
                hostPart = String(hostPart[hostPart.index(after: at)...])
            }
            guard !hostPart.isEmpty else { return nil }
            host = hostPart
            path = String(url[url.index(after: colon)...])
        } else {
            return nil
        }

        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard segments.count == 2 else { return nil }
        if segments[1].hasSuffix(".git") {
            segments[1] = String(segments[1].dropLast(4))
        }
        guard isValidSegment(segments[0]), isValidSegment(segments[1]) else { return nil }
        return HostedRepositoryRef(host: host, owner: segments[0], name: segments[1])
    }

    /// GitHub owner and repository names: letters, digits, `-`, `_`, `.`; never `.` or `..`.
    public static func isValidSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != "..", segment.count <= 100 else { return false }
        return segment.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    /// Removes `user:password@` from URLs so tokens embedded in remotes are never stored or logged.
    public static func redactingCredentials(_ rawURL: String) -> String {
        guard rawURL.contains("://"), var components = URLComponents(string: rawURL) else { return rawURL }
        if components.password != nil {
            components.password = nil
            components.user = nil
        } else if let user = components.user, user.lowercased() != "git" {
            // Single-token userinfo (https://<token>@github.com/...) is treated as a credential.
            components.user = nil
        }
        return components.string ?? rawURL
    }
}
