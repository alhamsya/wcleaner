import Foundation

public enum GitError: Error, Sendable, Equatable, CustomStringConvertible {
    case gitNotFound
    case unsupportedVersion(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case notAGitRepository(String)
    case malformedOutput(String)
    case process(ProcessRunnerError)

    public var description: String {
        switch self {
        case .gitNotFound:
            "Git was not found. Install the Xcode Command Line Tools (xcode-select --install) or Homebrew Git."
        case .unsupportedVersion(let version):
            "Git \(version) is too old. WCleaner requires Git \(GitClient.minimumVersion.description) or newer."
        case .commandFailed(let command, let exitCode, let stderr):
            "git \(command) failed (exit \(exitCode)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .notAGitRepository(let path):
            "Not a Git repository: \(path)"
        case .malformedOutput(let detail):
            "Unexpected Git output: \(detail)"
        case .process(let error):
            error.description
        }
    }
}

public struct GitVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses output such as `git version 2.39.5 (Apple Git-154)`.
    public init?(versionOutput: String) {
        let tokens = versionOutput.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let index = tokens.firstIndex(of: "version"), index + 1 < tokens.count else { return nil }
        let numbers = tokens[index + 1].split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Builds a minimal, predictable environment for Git subprocesses. The inherited environment is
/// allow-listed so variables like `GIT_DIR` or `GIT_WORK_TREE` can never redirect a command.
public enum GitEnvironment {
    public static func make(from base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = base[key] {
                environment[key] = value
            }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["GIT_ADVICE"] = "0"
        return environment
    }
}

/// Thin, injectable wrapper around the `git` executable. Every call passes discrete arguments,
/// uses `-C <path>` instead of changing directories, and has a timeout.
public struct GitClient: Sendable {
    public static let minimumVersion = GitVersion(major: 2, minor: 36, patch: 0)
    public static let candidatePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]

    public let executableURL: URL
    public let runner: any ProcessRunning
    public let environment: [String: String]
    public var defaultTimeout: Duration

    public init(
        executableURL: URL,
        runner: any ProcessRunning = SubprocessRunner(),
        environment: [String: String] = GitEnvironment.make(),
        defaultTimeout: Duration = .seconds(30)
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.environment = environment
        self.defaultTimeout = defaultTimeout
    }

    /// Finds a Git executable that reports at least `minimumVersion`.
    public static func locate(
        runner: any ProcessRunning = SubprocessRunner(),
        candidates: [String] = candidatePaths
    ) async throws -> (client: GitClient, version: GitVersion) {
        var lastError: GitError = .gitNotFound
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if path == "/usr/bin/git", !developerToolsInstalled() {
                // /usr/bin/git is a shim that would pop up an installer dialog.
                continue
            }
            let client = GitClient(executableURL: URL(fileURLWithPath: path), runner: runner)
            do {
                let version = try await client.version()
                if version >= minimumVersion {
                    return (client, version)
                }
                lastError = .unsupportedVersion(version.description)
            } catch let error as GitError {
                lastError = error
            }
        }
        throw lastError
    }

    private static func developerToolsInstalled() -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
            || fileManager.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") {
            return true
        }
        // The developer directory chosen with `xcode-select -s` (for example a renamed or beta Xcode).
        if let selected = try? fileManager.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            return fileManager.fileExists(atPath: selected + "/usr/bin/git")
        }
        return false
    }

    public func version() async throws -> GitVersion {
        let result = try await run(["--version"], timeout: .seconds(10))
        guard let version = GitVersion(versionOutput: result.stdoutString) else {
            throw GitError.malformedOutput("git --version")
        }
        return version
    }

    /// Runs git with the given arguments and throws when it exits non-zero.
    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: String? = nil,
        timeout: Duration? = nil,
        maxOutputBytes: Int = 8 * 1024 * 1024,
        allowFailure: Bool = false
    ) async throws -> ProcessResult {
        var fullArguments: [String] = []
        if let directory {
            fullArguments += ["-C", directory]
        }
        fullArguments += arguments
        let request = ProcessRequest(
            executableURL: executableURL,
            arguments: fullArguments,
            environment: environment,
            timeout: timeout ?? defaultTimeout,
            maxOutputBytes: maxOutputBytes
        )
        let result: ProcessResult
        do {
            result = try await runner.run(request)
        } catch let error as ProcessRunnerError {
            throw GitError.process(error)
        }
        if !allowFailure && !result.succeeded {
            throw GitError.commandFailed(
                command: arguments.first ?? "",
                exitCode: result.exitCode,
                stderr: String(result.stderrString.prefix(500))
            )
        }
        return result
    }

    // MARK: - Repository information

    public struct RepositoryLocation: Sendable, Equatable {
        public let commonDirectory: String
        public let gitDirectory: String
        public let isBare: Bool
        public let topLevel: String?
    }

    public func repositoryLocation(at path: String) async throws -> RepositoryLocation {
        let result = try await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir", "--is-bare-repository"],
            in: path,
            timeout: .seconds(15),
            allowFailure: true
        )
        guard result.succeeded else {
            throw GitError.notAGitRepository(path)
        }
        let lines = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else {
            throw GitError.malformedOutput("rev-parse")
        }
        let isBare = lines[2] == "true"
        var topLevel: String?
        if !isBare {
            let top = try await run(["rev-parse", "--show-toplevel"], in: path, timeout: .seconds(15), allowFailure: true)
            if top.succeeded {
                topLevel = top.stdoutString.trimmingCharacters(in: .newlines)
            }
        }
        return RepositoryLocation(commonDirectory: lines[0], gitDirectory: lines[1], isBare: isBare, topLevel: topLevel)
    }

    /// `git worktree list --porcelain -z`, parsed.
    public func worktreeList(repositoryPath: String) async throws -> [WorktreeRecord] {
        let result = try await run(["worktree", "list", "--porcelain", "-z"], in: repositoryPath, timeout: .seconds(20))
        return try WorktreePorcelainParser.parse(result.stdout)
    }

    /// Full status including untracked and ignored entries. Fails closed: any error propagates.
    public func status(worktreePath: String, timeout: Duration = .seconds(60)) async throws -> GitStatusSummary {
        let result = try await run(
            [
                // No fsmonitor or untracked cache: a stale cache must never hide a file.
                "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                "status", "--porcelain=v2", "-z", "--branch",
                // `matching` lists exactly what an ignore rule matched (`build/`, `src/debug.log`), never a
                // parent folder that merely happens to hold only ignored files.
                "--untracked-files=normal", "--ignored=matching", "--ignore-submodules=none",
            ],
            in: worktreePath,
            timeout: timeout,
            maxOutputBytes: 4 * 1024 * 1024
        )
        return try GitStatusParser.parse(result.stdout)
    }

    public func headSHA(worktreePath: String) async throws -> String {
        let result = try await run(["rev-parse", "--verify", "HEAD"], in: worktreePath, timeout: .seconds(15))
        let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitObjectID.isValid(sha) else {
            throw GitError.malformedOutput("rev-parse HEAD")
        }
        return sha
    }

    /// What the worktree's index says beyond `git status`.
    public struct IndexScan: Sendable, Equatable {
        /// Gitlink (submodule) entries, mode 160000.
        public var hasGitlinks: Bool { !gitlinkPaths.isEmpty }
        /// Paths of the gitlink entries, relative to the worktree root.
        public var gitlinkPaths: [String]
        /// Paths whose changes `git status` may not report: skip-worktree (`S`, also used by sparse
        /// checkout), assume-unchanged (lowercase tags) or any tag other than a plain cached `H`.
        /// Each path counts once, also when it has several merge stages.
        public var hiddenEntryCount: Int
    }

    /// Scans the index with `git ls-files -v -s -z`. Output lines are `<tag> <mode> <object> <stage>\t<path>`.
    public func indexScan(worktreePath: String) async throws -> IndexScan {
        let result = try await run(
            ["ls-files", "-v", "-s", "-z"],
            in: worktreePath,
            timeout: .seconds(60),
            maxOutputBytes: 64 * 1024 * 1024
        )
        var scan = IndexScan(gitlinkPaths: [], hiddenEntryCount: 0)
        var hiddenPaths = Set<Data>()
        let space = UInt8(ascii: " ")
        let tab = UInt8(ascii: "\t")
        for entry in result.stdout.split(separator: 0) {
            let fields = entry.split(separator: space, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0].count == 1, let tabIndex = fields[2].firstIndex(of: tab) else {
                throw GitError.malformedOutput("ls-files -v -s")
            }
            let path = Data(fields[2][fields[2].index(after: tabIndex)...])
            if fields[0].first != UInt8(ascii: "H") {
                hiddenPaths.insert(path)
            }
            if fields[1].elementsEqual("160000".utf8) {
                guard let text = String(data: path, encoding: .utf8), !text.isEmpty else {
                    throw GitError.malformedOutput("ls-files -v -s")
                }
                if !scan.gitlinkPaths.contains(text) { scan.gitlinkPaths.append(text) }
            }
        }
        scan.hiddenEntryCount = hiddenPaths.count
        return scan
    }

    /// Refs that belong to this worktree only and that `git worktree remove` deletes with it
    /// (`refs/worktree/*`, `refs/bisect/*`, `refs/rewritten/*`).
    public func perWorktreeRefs(worktreePath: String) async throws -> [String] {
        let result = try await run(
            ["for-each-ref", "--format=%(refname)", "refs/worktree", "refs/bisect", "refs/rewritten"],
            in: worktreePath,
            timeout: .seconds(15),
            maxOutputBytes: 1024 * 1024
        )
        return result.stdoutString.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// All `remote.<name>.url` values configured for the repository.
    public func remotes(repositoryPath: String) async throws -> [GitRemote] {
        let result = try await run(
            ["config", "--null", "--get-regexp", "^remote\\..*\\.url$"],
            in: repositoryPath,
            timeout: .seconds(10),
            allowFailure: true
        )
        // Exit code 1 means "no matching keys".
        if result.exitCode == 1 { return [] }
        guard result.succeeded else {
            throw GitError.commandFailed(command: "config", exitCode: result.exitCode, stderr: result.stderrString)
        }
        return GitRemote.parseConfigOutput(result.stdout)
    }

    /// The configured upstream (`branch.<name>.remote` / `branch.<name>.merge`) for a local branch.
    public func upstream(branch: String, repositoryPath: String) async throws -> BranchUpstream? {
        let remote = try await configValue("branch.\(branch).remote", repositoryPath: repositoryPath)
        let merge = try await configValue("branch.\(branch).merge", repositoryPath: repositoryPath)
        guard let remote, let merge, remote != "." else { return nil }
        let prefix = "refs/heads/"
        let remoteBranch = merge.hasPrefix(prefix) ? String(merge.dropFirst(prefix.count)) : merge
        return BranchUpstream(remoteName: remote, remoteBranch: remoteBranch)
    }

    /// Every configured branch upstream in one call (`branch.<name>.remote` / `branch.<name>.merge`).
    public func branchUpstreams(repositoryPath: String) async throws -> [String: BranchUpstream] {
        let result = try await run(
            ["config", "--null", "--get-regexp", "^branch\\..*\\.(remote|merge)$"],
            in: repositoryPath,
            timeout: .seconds(10),
            allowFailure: true
        )
        if result.exitCode == 1 { return [:] }
        guard result.succeeded else {
            throw GitError.commandFailed(command: "config", exitCode: result.exitCode, stderr: result.stderrString)
        }
        var remotes: [String: String] = [:]
        var merges: [String: String] = [:]
        for entry in result.stdout.split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8), let newline = text.firstIndex(of: "\n") else { continue }
            let key = String(text[..<newline])
            let value = String(text[text.index(after: newline)...])
            guard key.hasPrefix("branch.") else { continue }
            if key.hasSuffix(".remote") {
                remotes[String(key.dropFirst("branch.".count).dropLast(".remote".count))] = value
            } else if key.hasSuffix(".merge") {
                merges[String(key.dropFirst("branch.".count).dropLast(".merge".count))] = value
            }
        }
        var upstreams: [String: BranchUpstream] = [:]
        for (branch, remote) in remotes where remote != "." {
            guard let merge = merges[branch] else { continue }
            let prefix = "refs/heads/"
            upstreams[branch] = BranchUpstream(
                remoteName: remote,
                remoteBranch: merge.hasPrefix(prefix) ? String(merge.dropFirst(prefix.count)) : merge
            )
        }
        return upstreams
    }

    public func configValue(_ key: String, repositoryPath: String) async throws -> String? {
        let result = try await run(["config", "--get", key], in: repositoryPath, timeout: .seconds(10), allowFailure: true)
        if result.exitCode == 1 { return nil }
        guard result.succeeded else {
            throw GitError.commandFailed(command: "config", exitCode: result.exitCode, stderr: result.stderrString)
        }
        let value = result.stdoutString.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    /// The newest stash commit (`refs/stash` is shared by every worktree of a repository), or nil when the
    /// repository has none.
    public func latestStash(worktreePath: String) async throws -> StashCommit? {
        let lookup = try await run(["rev-parse", "--verify", "--quiet", "refs/stash"], in: worktreePath, timeout: .seconds(15), allowFailure: true)
        guard lookup.succeeded else {
            // Exit 1 without output means "no stash"; anything else is an error.
            if lookup.exitCode == 1 && lookup.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            throw GitError.commandFailed(command: "rev-parse", exitCode: lookup.exitCode, stderr: String(lookup.stderrString.prefix(500)))
        }
        let sha = lookup.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitObjectID.isValid(sha) else { throw GitError.malformedOutput("rev-parse refs/stash") }
        let show = try await run(["show", "-s", "--format=%H%x00%P%x00%s", sha, "--"], in: worktreePath, timeout: .seconds(15))
        let fields = show.stdoutString.trimmingCharacters(in: .newlines).components(separatedBy: "\u{0}")
        guard fields.count == 3, fields[0] == sha else { throw GitError.malformedOutput("show refs/stash") }
        let parents = fields[1].split(separator: " ").map(String.init)
        guard parents.allSatisfy(GitObjectID.isValid) else { throw GitError.malformedOutput("show refs/stash") }
        return StashCommit(sha: sha, parents: parents, subject: fields[2])
    }

    /// Saves the worktree's staged, unstaged and untracked changes in a new stash and resets the worktree to
    /// HEAD (`git stash push --include-untracked --message <message>`). Ignored files are neither saved nor
    /// touched. Hooks, fsmonitor and the untracked cache are off. Never `--all`, never drop, pop or clear.
    public func stashPush(worktreePath: String, message: String) async throws {
        try await run(
            [
                "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                "stash", "push", "--include-untracked", "--message", message,
            ],
            in: worktreePath,
            timeout: .seconds(600),
            maxOutputBytes: 1024 * 1024
        )
    }

    /// Removes a linked worktree. Never uses `--force`; a refusal from Git is final.
    public func removeWorktree(repositoryPath: String, worktreePath: String) async throws {
        try await run(["worktree", "remove", "--", worktreePath], in: repositoryPath, timeout: .seconds(120))
    }
}

/// A stash commit: its first parent is the HEAD it was made on, the second holds the index, and a third (only
/// with untracked files) holds the untracked files.
public struct StashCommit: Sendable, Equatable {
    public let sha: String
    public let parents: [String]
    public let subject: String
}

public struct BranchUpstream: Sendable, Equatable {
    public let remoteName: String
    public let remoteBranch: String
}

public enum GitObjectID {
    /// SHA-1 (40) or SHA-256 (64) lowercase hex object name.
    public static func isValid(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
