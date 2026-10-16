import Foundation
import XCTest
@testable import WCleanerCore

/// A freshly generated, disposable Git repository under the system temporary directory.
/// Integration tests only ever touch these; they are deleted in `cleanup()`.
final class TemporaryGitRepository {
    static let gitPath = "/usr/bin/git"

    /// Canonical (symlink-free) root containing the repository and its worktrees.
    let root: String
    let repositoryPath: String

    /// Environment that ignores the developer's global/system Git config (signing, hooks, aliases).
    static var isolatedEnvironment: [String: String] {
        var environment = GitEnvironment.make()
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "WCleaner Tests"
        environment["GIT_AUTHOR_EMAIL"] = "tests@wcleaner.invalid"
        environment["GIT_COMMITTER_NAME"] = "WCleaner Tests"
        environment["GIT_COMMITTER_EMAIL"] = "tests@wcleaner.invalid"
        return environment
    }

    static var client: GitClient {
        GitClient(executableURL: URL(fileURLWithPath: gitPath), environment: isolatedEnvironment)
    }

    init(name: String = "repo") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = PathCanonicalizer.realPath(base.path) else {
            throw NSError(domain: "TemporaryGitRepository", code: 1)
        }
        precondition(resolved.contains("WCleanerTests-"), "Refusing to operate outside a test directory")
        root = resolved
        repositoryPath = resolved + "/" + name
        try FileManager.default.createDirectory(atPath: repositoryPath, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try write("README.md", "hello\n")
        try git(["add", "README.md"])
        try git(["commit", "-q", "-m", "Initial commit"])
    }

    func cleanup() {
        precondition(root.contains("WCleanerTests-"))
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = ["-C", directory ?? repositoryPath] + arguments
        process.environment = Self.isolatedEnvironment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(String(decoding: errorData, as: UTF8.self))",
            ])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a linked worktree on a new branch and returns its canonical path.
    @discardableResult
    func addWorktree(_ name: String, branch: String) throws -> String {
        let path = root + "/" + name
        try git(["worktree", "add", "-q", "-b", branch, path])
        return path
    }

    func write(_ relativePath: String, _ contents: String, in directory: String? = nil) throws {
        let url = URL(fileURLWithPath: (directory ?? repositoryPath) + "/" + relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func head(of directory: String? = nil) throws -> String {
        try git(["rev-parse", "HEAD"], in: directory)
    }

    func commonDirectory() throws -> String {
        let raw = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        return PathCanonicalizer.realPath(raw) ?? raw
    }
}
