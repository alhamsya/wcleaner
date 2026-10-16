import Foundation

/// Read-only local facts about one linked worktree, gathered for the safety evaluator.
public struct LocalWorktreeInspection: Sendable, Equatable, Codable {
    public enum GitFileStatus: Sendable, Equatable, Codable {
        /// `.git` is a file pointing at `<common-dir>/worktrees/<id>` and that entry points back.
        case valid
        case missing
        /// `.git` is a directory: this is an independent repository, not a linked worktree.
        case isDirectory
        case mismatch(String)
    }

    public var path: String
    public var exists: Bool
    public var isDirectory: Bool
    public var isSymlinkAmbiguous: Bool
    public var gitFileStatus: GitFileStatus
    public var worktreeGitDirectory: String?
    public var status: GitStatusSummary?
    public var statusError: String?
    public var headSHA: String?
    public var headError: String?
    public var hasGitmodulesFile: Bool
    public var hasSubmoduleGitDirectories: Bool
    /// Only checked during deep inspection (immediately before removal); nil means "not checked".
    public var hasGitlinks: Bool?
    public var gitlinkCheckError: String?
    /// Index entries whose changes `git status` cannot show (skip-worktree, assume-unchanged). Nil until a deep check ran.
    public var hiddenIndexEntryCount: Int?
    /// Refs owned by this worktree alone, deleted together with it. Nil until a deep check ran.
    public var perWorktreeRefs: [String]?
    public var perWorktreeRefsError: String?
    /// `.git` entries below the top level, which Git hides from `status` and `worktree remove` deletes.
    /// Nil until a deep check ran.
    public var nestedGitEntries: [String]?
    public var nestedGitScanError: String?
    public var operationsInProgress: [String]
    public var inspectedAt: Date

    public init(
        path: String,
        exists: Bool = true,
        isDirectory: Bool = true,
        isSymlinkAmbiguous: Bool = false,
        gitFileStatus: GitFileStatus = .valid,
        worktreeGitDirectory: String? = nil,
        status: GitStatusSummary? = GitStatusSummary(),
        statusError: String? = nil,
        headSHA: String? = nil,
        headError: String? = nil,
        hasGitmodulesFile: Bool = false,
        hasSubmoduleGitDirectories: Bool = false,
        hasGitlinks: Bool? = nil,
        gitlinkCheckError: String? = nil,
        hiddenIndexEntryCount: Int? = nil,
        perWorktreeRefs: [String]? = nil,
        perWorktreeRefsError: String? = nil,
        nestedGitEntries: [String]? = nil,
        nestedGitScanError: String? = nil,
        operationsInProgress: [String] = [],
        inspectedAt: Date = Date()
    ) {
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.isSymlinkAmbiguous = isSymlinkAmbiguous
        self.gitFileStatus = gitFileStatus
        self.worktreeGitDirectory = worktreeGitDirectory
        self.status = status
        self.statusError = statusError
        self.headSHA = headSHA
        self.headError = headError
        self.hasGitmodulesFile = hasGitmodulesFile
        self.hasSubmoduleGitDirectories = hasSubmoduleGitDirectories
        self.hasGitlinks = hasGitlinks
        self.gitlinkCheckError = gitlinkCheckError
        self.hiddenIndexEntryCount = hiddenIndexEntryCount
        self.perWorktreeRefs = perWorktreeRefs
        self.perWorktreeRefsError = perWorktreeRefsError
        self.nestedGitEntries = nestedGitEntries
        self.nestedGitScanError = nestedGitScanError
        self.operationsInProgress = operationsInProgress
        self.inspectedAt = inspectedAt
    }

    /// True when every deep check ran to completion.
    public var hasDeepResults: Bool {
        hasGitlinks != nil && hiddenIndexEntryCount != nil && perWorktreeRefs != nil && nestedGitEntries != nil
    }
}

public struct WorktreeInspector: Sendable {
    public enum Depth: Sendable {
        /// Used on every scan: filesystem checks, status (with ignored files) and HEAD.
        case standard
        /// Used for worktrees that look removable and immediately before removal: adds a scan of the index
        /// (gitlinks, skip-worktree and assume-unchanged entries), per-worktree refs and nested `.git` entries.
        case deep
    }

    private static let inProgressMarkers: [(file: String, label: String)] = [
        ("MERGE_HEAD", "merge"),
        ("CHERRY_PICK_HEAD", "cherry-pick"),
        ("REVERT_HEAD", "revert"),
        ("BISECT_LOG", "bisect"),
        ("rebase-merge", "rebase"),
        ("rebase-apply", "rebase or am"),
    ]

    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public func inspect(
        record: WorktreeRecord,
        commonDirectory: String,
        depth: Depth,
        now: Date = Date()
    ) async -> LocalWorktreeInspection {
        let fileManager = FileManager.default
        let path = record.path
        var inspection = LocalWorktreeInspection(
            path: path,
            status: nil,
            inspectedAt: now
        )

        // Existence without following a final symlink.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else {
            inspection.exists = false
            inspection.isDirectory = false
            inspection.gitFileStatus = .missing
            return inspection
        }
        if type == .typeSymbolicLink {
            inspection.isSymlinkAmbiguous = true
        }
        var isDirectory: ObjCBool = false
        inspection.isDirectory = fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        guard inspection.isDirectory else {
            return inspection
        }
        if PathCanonicalizer.realPath(path) != PathCanonicalizer.standardize(path) {
            inspection.isSymlinkAmbiguous = true
        }

        let (gitFileStatus, worktreeGitDirectory) = Self.verifyGitFile(worktreePath: path, commonDirectory: commonDirectory)
        inspection.gitFileStatus = gitFileStatus
        inspection.worktreeGitDirectory = worktreeGitDirectory

        inspection.hasGitmodulesFile = (try? fileManager.attributesOfItem(atPath: path + "/.gitmodules")) != nil
        if let worktreeGitDirectory {
            inspection.hasSubmoduleGitDirectories = fileManager.fileExists(atPath: worktreeGitDirectory + "/modules")
            inspection.operationsInProgress = Self.inProgressMarkers
                .filter { fileManager.fileExists(atPath: worktreeGitDirectory + "/" + $0.file) }
                .map(\.label)
        }

        guard gitFileStatus == .valid else {
            return inspection
        }

        do {
            inspection.status = try await git.status(worktreePath: path)
        } catch {
            inspection.statusError = String(describing: error)
        }
        do {
            inspection.headSHA = try await git.headSHA(worktreePath: path)
        } catch {
            inspection.headError = String(describing: error)
        }
        if depth == .deep {
            do {
                let scan = try await git.indexScan(worktreePath: path)
                inspection.hasGitlinks = scan.hasGitlinks
                inspection.hiddenIndexEntryCount = scan.hiddenEntryCount
            } catch {
                inspection.gitlinkCheckError = String(describing: error)
            }
            do {
                inspection.perWorktreeRefs = try await git.perWorktreeRefs(worktreePath: path)
            } catch {
                inspection.perWorktreeRefsError = String(describing: error)
            }
            do {
                inspection.nestedGitEntries = try NestedGitScanner.scan(worktreePath: path)
            } catch {
                inspection.nestedGitScanError = String(describing: error)
            }
        }
        return inspection
    }

    /// Confirms `<worktree>/.git` is a `gitdir:` file that points into `<common-dir>/worktrees/`
    /// and that the administrative entry points back at this worktree.
    static func verifyGitFile(
        worktreePath: String,
        commonDirectory: String
    ) -> (LocalWorktreeInspection.GitFileStatus, String?) {
        let fileManager = FileManager.default
        let dotGit = worktreePath + "/.git"
        guard let attributes = try? fileManager.attributesOfItem(atPath: dotGit),
              let type = attributes[.type] as? FileAttributeType else {
            return (.missing, nil)
        }
        if type == .typeDirectory {
            return (.isDirectory, nil)
        }
        guard type == .typeRegular,
              let handle = FileHandle(forReadingAtPath: dotGit) else {
            return (.mismatch("The .git entry is not a regular file."), nil)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              content.hasPrefix("gitdir: ") else {
            return (.mismatch("The .git file has no gitdir line."), nil)
        }
        var gitDirectory = String(content.dropFirst("gitdir: ".count))
        if !gitDirectory.hasPrefix("/") {
            gitDirectory = worktreePath + "/" + gitDirectory
        }
        guard let resolvedGitDirectory = PathCanonicalizer.realPath(gitDirectory),
              let resolvedCommon = PathCanonicalizer.realPath(commonDirectory) else {
            return (.mismatch("The worktree's Git directory does not exist."), nil)
        }
        let worktreesRoot = resolvedCommon + "/worktrees"
        guard PathCanonicalizer.isPath(resolvedGitDirectory, inside: worktreesRoot),
              resolvedGitDirectory != worktreesRoot else {
            return (.mismatch("The worktree belongs to a different repository."), resolvedGitDirectory)
        }

        // The administrative entry must point back at this worktree's .git file.
        guard let backData = fileManager.contents(atPath: resolvedGitDirectory + "/gitdir"),
              let backPointer = String(data: backData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !backPointer.isEmpty else {
            return (.mismatch("The worktree's administrative entry is missing its back-pointer."), resolvedGitDirectory)
        }
        let resolvedBack = PathCanonicalizer.realPath(backPointer) ?? PathCanonicalizer.standardize(backPointer)
        let resolvedDotGit = PathCanonicalizer.realPath(dotGit) ?? PathCanonicalizer.standardize(dotGit)
        guard resolvedBack == resolvedDotGit else {
            return (.mismatch("The worktree's administrative entry points to a different location."), resolvedGitDirectory)
        }
        return (.valid, resolvedGitDirectory)
    }
}
