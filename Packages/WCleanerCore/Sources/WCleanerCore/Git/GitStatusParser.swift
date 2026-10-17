import Foundation

/// Summary of `git status --porcelain=v2 -z --branch --untracked-files=normal --ignored=matching`.
public struct GitStatusSummary: Sendable, Equatable, Codable {
    public var branchHead: String?
    public var commit: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var stagedCount: Int
    public var unstagedCount: Int
    public var unmergedCount: Int
    public var untrackedCount: Int
    public var ignoredCount: Int
    /// The ignored entries, relative to the worktree root, as the ignore rules matched them (an ignored folder
    /// ends in `/` and stands for everything inside it).
    /// At most `ignoredPathLimit` of them; `ignoredPathsComplete` is false when Git reported more.
    public var ignoredPaths: [String]
    public var ignoredPathsComplete: Bool
    public var submoduleChangeCount: Int

    public static let ignoredPathLimit = 500

    public init(
        branchHead: String? = nil,
        commit: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        stagedCount: Int = 0,
        unstagedCount: Int = 0,
        unmergedCount: Int = 0,
        untrackedCount: Int = 0,
        ignoredCount: Int = 0,
        ignoredPaths: [String] = [],
        ignoredPathsComplete: Bool = true,
        submoduleChangeCount: Int = 0
    ) {
        self.branchHead = branchHead
        self.commit = commit
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.stagedCount = stagedCount
        self.unstagedCount = unstagedCount
        self.unmergedCount = unmergedCount
        self.untrackedCount = untrackedCount
        self.ignoredCount = ignoredCount
        self.ignoredPaths = ignoredPaths
        self.ignoredPathsComplete = ignoredPathsComplete
        self.submoduleChangeCount = submoduleChangeCount
    }

    /// True only when there are no staged, unstaged, unmerged, untracked, ignored or submodule entries.
    public var isCompletelyClean: Bool {
        stagedCount == 0 && unstagedCount == 0 && unmergedCount == 0
            && untrackedCount == 0 && ignoredCount == 0 && submoduleChangeCount == 0
    }
}

public enum GitStatusParser {
    public enum ParseError: Error, Equatable, Sendable {
        case invalidEncoding
        case unknownEntry(String)
        case truncatedEntry
    }

    public static func parse(_ data: Data) throws -> GitStatusSummary {
        var summary = GitStatusSummary()
        let fields = data.split(separator: 0, omittingEmptySubsequences: true)
        var index = fields.startIndex

        while index < fields.endIndex {
            guard let line = String(data: Data(fields[index]), encoding: .utf8) else {
                throw ParseError.invalidEncoding
            }
            index = fields.index(after: index)
            guard let kind = line.first else { continue }

            switch kind {
            case "#":
                parseHeader(line, into: &summary)
            case "1", "2":
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count >= 9 else { throw ParseError.truncatedEntry }
                countXY(parts[1], submodule: parts[2], into: &summary)
                if kind == "2" {
                    // Renames/copies carry the original path as an extra NUL-terminated field.
                    guard index < fields.endIndex else { throw ParseError.truncatedEntry }
                    index = fields.index(after: index)
                }
            case "u":
                summary.unmergedCount += 1
            case "?":
                summary.untrackedCount += 1
            case "!":
                summary.ignoredCount += 1
                let path = String(line.dropFirst(2))
                guard line.hasPrefix("! "), !path.isEmpty else { throw ParseError.truncatedEntry }
                if summary.ignoredPaths.count < GitStatusSummary.ignoredPathLimit {
                    summary.ignoredPaths.append(path)
                } else {
                    summary.ignoredPathsComplete = false
                }
            default:
                throw ParseError.unknownEntry(String(kind))
            }
        }
        return summary
    }

    private static func parseHeader(_ line: String, into summary: inout GitStatusSummary) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return }
        let value = parts[2...].joined(separator: " ")
        switch parts[1] {
        case "branch.oid":
            summary.commit = value == "(initial)" ? nil : value
        case "branch.head":
            summary.branchHead = value == "(detached)" ? nil : value
        case "branch.upstream":
            summary.upstream = value
        case "branch.ab":
            if parts.count >= 4 {
                summary.ahead = Int(parts[2].dropFirst())
                summary.behind = Int(parts[3].dropFirst())
            }
        default:
            break
        }
    }

    private static func countXY(_ xy: Substring, submodule: Substring, into summary: inout GitStatusSummary) {
        let characters = Array(xy)
        guard characters.count == 2 else { return }
        if characters[0] != "." { summary.stagedCount += 1 }
        if characters[1] != "." { summary.unstagedCount += 1 }
        if submodule.first == "S" { summary.submoduleChangeCount += 1 }
    }
}
