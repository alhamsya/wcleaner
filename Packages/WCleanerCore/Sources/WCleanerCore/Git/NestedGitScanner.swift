import Foundation

/// Finds entries named `.git` below a worktree's top level. Git skips them in `status` (even with
/// `--ignored`), and `git worktree remove` deletes them without asking, so a stray `.git` folder or a
/// broken nested clone would be lost silently. Read-only; never follows symbolic links.
public enum NestedGitScanner {
    public enum ScanError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case tooManyEntries(Int)
        case timedOut(Int)

        public var description: String {
            switch self {
            case .unreadable(let detail): "A folder in the worktree could not be read: \(detail)"
            case .tooManyEntries(let limit): "The worktree has more than \(limit) files and folders."
            case .timedOut(let seconds): "Checking the worktree's folders took longer than \(seconds) seconds."
            }
        }
    }

    /// Code points HFS+ ignores in file names, which Git also ignores when it protects `.git` on macOS.
    private static let ignorableScalars: Set<UInt32> = Set(
        [0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0xFEFF]
            + Array(0x206A...0x206F)
    )

    /// True for `.git` in any letter case, also with HFS-ignorable code points mixed in.
    public static func isGitName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars.filter { !ignorableScalars.contains($0.value) }
        return String(String.UnicodeScalarView(scalars)).lowercased() == ".git"
    }

    /// Relative paths of nested `.git` entries (at most `reportLimit` of them). The worktree's own top-level
    /// `.git` file is not reported. Any unreadable folder, or a tree larger than the limits, throws.
    public static func scan(
        worktreePath: String,
        maximumEntries: Int = 2_000_000,
        timeLimit: TimeInterval = 60,
        reportLimit: Int = 20
    ) throws -> [String] {
        let root = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let rootComponents = root.standardizedFileURL.pathComponents.count
        var failure: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { url, error in
                failure = "\(url.path): \(error.localizedDescription)"
                return false
            }
        ) else {
            throw ScanError.unreadable(worktreePath)
        }

        let deadline = Date().addingTimeInterval(timeLimit)
        var found: [String] = []
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > maximumEntries { throw ScanError.tooManyEntries(maximumEntries) }
            if count % 4096 == 0, Date() > deadline { throw ScanError.timedOut(Int(timeLimit)) }

            let isTopLevel = enumerator.level == 1
            let name = url.lastPathComponent
            if isGitName(name), !(isTopLevel && name == ".git") {
                if found.count < reportLimit {
                    let components = url.standardizedFileURL.pathComponents.dropFirst(rootComponents)
                    found.append(components.joined(separator: "/"))
                } else {
                    break
                }
            }
            // The enumerator never descends into symbolic links. `skipDescendants()` applies to the most
            // recently returned *directory*, so it is called only while that is the current entry.
            if isTopLevel && name == ".git" {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true {
                    enumerator.skipDescendants()
                }
            }
        }
        if let failure { throw ScanError.unreadable(failure) }
        return found
    }
}
