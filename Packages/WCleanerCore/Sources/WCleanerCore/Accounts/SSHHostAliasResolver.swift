import Darwin
import Foundation

public protocol SSHHostAliasResolving: Sendable {
    /// The real host name for an SSH alias such as `github-work`, or nil when unknown.
    func hostName(for alias: String) async -> String?
}

/// Resolves `Host` aliases by reading `~/.ssh/config` as text. It never runs `ssh`, so `Match exec`
/// or `ProxyCommand` entries are never executed. `Include` directives are followed (one level of globs).
public actor SSHConfigHostAliasResolver: SSHHostAliasResolving {
    private let configPath: String
    private var cache: [String: String?] = [:]

    public init(configPath: String = NSHomeDirectory() + "/.ssh/config") {
        self.configPath = configPath
    }

    public func hostName(for alias: String) async -> String? {
        if let cached = cache[alias] { return cached }
        let resolved = SSHConfigParser.hostName(for: alias, configPath: configPath)
        cache[alias] = resolved
        return resolved
    }
}

enum SSHConfigParser {
    static func hostName(for alias: String, configPath: String, depth: Int = 0) -> String? {
        guard depth < 4, let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        return hostName(for: alias, configText: text, baseDirectory: (configPath as NSString).deletingLastPathComponent, depth: depth)
    }

    static func hostName(for alias: String, configText: String, baseDirectory: String = NSHomeDirectory() + "/.ssh", depth: Int = 0) -> String? {
        var currentPatterns: [String] = ["*"]
        for rawLine in configText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let keyword = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch keyword {
            case "host":
                currentPatterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            case "match":
                // Match blocks may depend on runtime state; never guess about them.
                currentPatterns = []
            case "hostname":
                if matches(alias, patterns: currentPatterns) {
                    return value.replacingOccurrences(of: "%h", with: alias)
                }
            case "include":
                guard matches(alias, patterns: currentPatterns) else { continue }
                for pattern in value.split(separator: " ").map(String.init) {
                    for file in expandInclude(pattern, baseDirectory: baseDirectory) {
                        if let found = hostName(for: alias, configPath: file, depth: depth + 1) {
                            return found
                        }
                    }
                }
            default:
                continue
            }
        }
        return nil
    }

    /// OpenSSH semantics: any positive match and no negated (`!pattern`) match.
    static func matches(_ alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false }
            } else if fnmatch(pattern, alias, 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    private static func expandInclude(_ pattern: String, baseDirectory: String) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = baseDirectory + "/" + path
        }
        var results: [String] = []
        var globResult = glob_t()
        defer { globfree(&globResult) }
        if glob(path, 0, nil, &globResult) == 0 {
            for index in 0..<Int(globResult.gl_pathc) {
                if let cString = globResult.gl_pathv[index] {
                    results.append(String(cString: cString))
                }
            }
        }
        return results
    }
}
