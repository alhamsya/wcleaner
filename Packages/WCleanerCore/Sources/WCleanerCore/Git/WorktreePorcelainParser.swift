import Foundation

/// One entry of `git worktree list --porcelain -z`.
public struct WorktreeRecord: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var head: String?
    public var branchRef: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var lockReason: String?
    public var isPrunable: Bool
    public var prunableReason: String?
    /// Attributes this parser does not understand. Their presence makes the worktree ambiguous.
    public var unknownAttributes: [String]

    public init(
        path: String,
        head: String? = nil,
        branchRef: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false,
        prunableReason: String? = nil,
        unknownAttributes: [String] = []
    ) {
        self.path = path
        self.head = head
        self.branchRef = branchRef
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.prunableReason = prunableReason
        self.unknownAttributes = unknownAttributes
    }

    /// Short branch name (`feature/x`) for `refs/heads/feature/x`.
    public var branchName: String? {
        guard let branchRef else { return nil }
        let prefix = "refs/heads/"
        return branchRef.hasPrefix(prefix) ? String(branchRef.dropFirst(prefix.count)) : nil
    }
}

public enum WorktreePorcelainParser {
    public enum ParseError: Error, Equatable, Sendable {
        case attributeOutsideRecord(String)
        case invalidEncoding
        case relativePath(String)
        case invalidHead(String)
    }

    /// Parses NUL-delimited porcelain output. Each attribute ends with NUL and each record ends
    /// with an empty attribute, so paths and lock reasons may contain spaces or newlines.
    public static func parse(_ data: Data) throws -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?

        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let record = current {
                    records.append(record)
                    current = nil
                }
                continue
            }
            guard let line = String(data: Data(field), encoding: .utf8) else {
                throw ParseError.invalidEncoding
            }
            let key: String
            let value: String?
            if let space = line.firstIndex(of: " ") {
                key = String(line[..<space])
                value = String(line[line.index(after: space)...])
            } else {
                key = line
                value = nil
            }

            if key == "worktree" {
                if let record = current {
                    records.append(record)
                }
                guard let path = value, path.hasPrefix("/") else {
                    throw ParseError.relativePath(value ?? "")
                }
                current = WorktreeRecord(path: path)
                continue
            }

            guard var record = current else {
                throw ParseError.attributeOutsideRecord(key)
            }
            switch key {
            case "HEAD":
                guard let sha = value, GitObjectID.isValid(sha) else {
                    throw ParseError.invalidHead(value ?? "")
                }
                record.head = sha
            case "branch":
                record.branchRef = value
            case "bare":
                record.isBare = true
            case "detached":
                record.isDetached = true
            case "locked":
                record.isLocked = true
                record.lockReason = value
            case "prunable":
                record.isPrunable = true
                record.prunableReason = value
            default:
                record.unknownAttributes.append(key)
            }
            current = record
        }

        if let record = current {
            records.append(record)
        }
        return records
    }
}
