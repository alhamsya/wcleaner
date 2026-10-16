import Foundation

/// Estimated on-disk size of a worktree. Unknown and failed values are never shown as zero.
public enum DiskUsageValue: Sendable, Equatable {
    case unknown
    case measuring
    /// `partial` is true when `du` could not read some entries; the value is then a lower bound.
    case measured(bytes: Int64, measuredAt: Date, partial: Bool)
    case failed(String)

    public var bytes: Int64? {
        if case .measured(let bytes, _, _) = self { return bytes }
        return nil
    }

    public var displayString: String {
        switch self {
        case .unknown: "Size unknown"
        case .measuring: "Measuring…"
        case .measured(let bytes, _, let partial): (partial ? "≥ " : "") + ByteFormatter.string(bytes)
        case .failed: "Size unavailable"
        }
    }
}

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Sums of measured sizes plus a count of entries whose size is not known.
public struct DiskUsageTotal: Sendable, Equatable {
    public var bytes: Int64 = 0
    public var unknownCount: Int = 0
    public var hasPartial = false
    public var itemCount: Int = 0

    public init() {}

    public mutating func add(_ value: DiskUsageValue) {
        itemCount += 1
        switch value {
        case .measured(let bytes, _, let partial):
            self.bytes += bytes
            hasPartial = hasPartial || partial
        default:
            unknownCount += 1
        }
    }

    public var displayString: String {
        if itemCount == 0 { return ByteFormatter.string(0) }
        if unknownCount == itemCount { return "Unknown" }
        let base = ByteFormatter.string(bytes)
        if unknownCount > 0 || hasPartial {
            return "≥ \(base)" + (unknownCount > 0 ? " (\(unknownCount) not measured)" : "")
        }
        return base
    }
}
