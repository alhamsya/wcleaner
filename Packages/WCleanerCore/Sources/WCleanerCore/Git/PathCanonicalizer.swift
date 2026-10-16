import Foundation

public enum PathCanonicalizer {
    /// Resolves symlinks and `.`/`..` components with `realpath(3)`. Returns nil when the path does not exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Lexically standardizes an absolute path (collapses `//`, `.`, `..`, trailing `/`) without touching disk.
    /// Deliberately avoids `NSString.standardizingPath`, which silently rewrites `/private/...` prefixes.
    public static func standardize(_ path: String) -> String {
        var components: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(part)
        }
        return "/" + components.joined(separator: "/")
    }

    /// True when `child` equals `parent` or lies inside it, comparing whole path components.
    public static func isPath(_ child: String, inside parent: String) -> Bool {
        let childComponents = standardize(child).split(separator: "/")
        let parentComponents = standardize(parent).split(separator: "/")
        guard childComponents.count >= parentComponents.count else { return false }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }
}
