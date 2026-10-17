import Foundation

/// The rules for a repository's disposable ignored paths: exact paths relative to the worktree root, no
/// wildcards. An entry covers that file or folder and everything inside it, nothing else.
public enum DisposablePaths {
    /// The canonical form of a user-entered path (`./build/` → `build`), or nil when it is not a safe,
    /// exact relative path: empty, `.` or `..` components, wildcards, control characters, or a `.git` entry.
    public static func normalize(_ input: String) -> String? {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path.count <= 1024 else { return nil }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "*?[\\".unicodeScalars.contains($0) }) else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !NestedGitScanner.isGitName($0) }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    /// Normalized, de-duplicated and sorted; invalid entries are dropped.
    public static func normalizedList(_ paths: [String]) -> [String] {
        Array(Set(paths.compactMap(normalize))).sorted()
    }

    /// True when `ignoredPath` (as reported by `git status`, folders ending in `/`) is one of `disposable`
    /// or lies inside one of them.
    public static func covers(_ disposable: [String], _ ignoredPath: String) -> Bool {
        var path = ignoredPath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return false }
        return disposable.contains { entry in
            !entry.isEmpty && (path == entry || path.hasPrefix(entry + "/"))
        }
    }
}
