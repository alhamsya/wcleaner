import Foundation

/// Why a worktree is (not) safe to remove. Every blocking condition has a human-readable English message.
public enum EligibilityReason: Sendable, Hashable {
    // Worktree structure
    case primaryWorktree
    case bareRepository
    case locked(String?)
    case prunable(String?)
    case detachedHead
    case unknownWorktreeAttributes([String])
    case missingDirectory
    case notADirectory
    case symlinkAmbiguous
    case notALinkedWorktree(String)
    case containsOtherWorktree(String)
    case containsRepositoryData
    /// The worktree's own Git directory stores submodule repositories (`modules/`); Git would delete them.
    case submodules
    /// Submodules whose folders hold files in this worktree; those files would be deleted.
    case checkedOutSubmodules([String])

    // Local content
    case statusUnavailable(String)
    case stagedChanges(Int)
    case unstagedChanges(Int)
    case unmergedChanges(Int)
    case untrackedFiles(Int)
    /// Ignored files and folders that are not on the repository's list of disposable paths. `paths` lists
    /// those Git reported (it can be shorter than the count when Git reported very many).
    case ignoredFiles(Int, paths: [String] = [])
    /// Informational: ignored files the user marked as disposable for this repository, deleted with the worktree.
    case disposableIgnoredFiles([String])
    case submoduleChanges(Int)
    case operationInProgress(String)
    /// Files marked skip-worktree or assume-unchanged: Git hides their changes from `status`.
    case hiddenIndexEntries(Int)
    /// Refs such as `refs/worktree/*` or `refs/bisect/*` that are deleted with the worktree.
    case perWorktreeRefs([String])
    /// Folders or files named `.git` inside the worktree: invisible to Git, deleted with the worktree.
    case nestedGitEntries([String])
    case headUnavailable(String)
    case headChangedDuringCheck

    // Hosting evidence
    case notGitHubRepository(String)
    case needsAccount
    case needsAccountSelection
    case accountUnavailable(String)
    case accountUnverified(String)
    case repositoryIdentityMismatch(String)
    case noPullRequest
    case pullRequestLookupFailed(String)
    case ambiguousPullRequest([Int])
    case headDiffersFromPullRequest(local: String, pullRequest: String)
    case pullRequestOpen(Int)
    case pullRequestClosedUnmerged(Int)
    case pullRequestStateUnknown(Int)
    case headRepositoryUnverified

    // Policy
    case mergedBeforeEnrollment(Date)
    case waitingForDelay(until: Date)
    case cleanupConsentMissing
    case automaticCleanupOff
    case automaticCleanupPaused

    // Execution-time guards
    case deletionDisabledInDevelopmentBuild
    case anotherCleanupInProgress
    case worktreeNoLongerListed
    case expectationChanged(String)
    /// Informational: the worktree's uncommitted changes were saved in this stash commit before removal.
    case changesStashed(String)
    /// Git did not save the changes in a stash in a way WCleaner could confirm; nothing is removed.
    case stashNotConfirmed(String)

    public enum Kind: Sendable {
        /// Prevents any removal.
        case blocking
        /// Prevents removal until the user reviews this specific worktree.
        case review
        /// Informational: safe, but automation will not act right now.
        case info
    }

    public var kind: Kind {
        switch self {
        case .mergedBeforeEnrollment:
            .review
        case .waitingForDelay, .cleanupConsentMissing, .automaticCleanupOff, .automaticCleanupPaused, .disposableIgnoredFiles,
             .changesStashed:
            .info
        default:
            .blocking
        }
    }

    public var message: String {
        switch self {
        case .primaryWorktree: "This is the repository's primary worktree and is never removed."
        case .bareRepository: "This is a bare repository entry and is never removed."
        case .locked(let reason):
            reason.map { "The worktree is locked: \($0)" } ?? "The worktree is locked."
        case .prunable(let reason):
            reason.map { "Git reports this worktree as prunable: \($0)" } ?? "Git reports this worktree as prunable."
        case .detachedHead: "The worktree has a detached HEAD (no branch checked out)."
        case .unknownWorktreeAttributes(let names):
            "Git reported attributes WCleaner does not understand: \(names.joined(separator: ", "))."
        case .missingDirectory: "The worktree directory does not exist."
        case .notADirectory: "The worktree path is not a directory."
        case .symlinkAmbiguous: "The worktree path involves a symbolic link, so its location is ambiguous."
        case .notALinkedWorktree(let detail): "The directory could not be confirmed as a linked worktree of this repository. \(detail)"
        case .containsOtherWorktree(let path): "Another worktree is nested inside this one: \(path)"
        case .containsRepositoryData: "The repository's primary worktree or Git directory is inside this worktree."
        case .submodules: "Submodule repositories are stored in this worktree's Git folder (modules); Git would delete them."
        case .checkedOutSubmodules(let paths):
            "\(paths.count == 1 ? "A submodule is" : "Submodules are") checked out in this worktree and \(paths.count == 1 ? "its" : "their") files would be deleted: \(Self.list(paths))."
        case .statusUnavailable(let detail): "Local changes could not be checked: \(detail)"
        case .stagedChanges(let count): "\(count) staged change\(count == 1 ? "" : "s") would be lost."
        case .unstagedChanges(let count): "\(count) unstaged change\(count == 1 ? "" : "s") would be lost."
        case .unmergedChanges(let count): "\(count) unresolved merge conflict\(count == 1 ? "" : "s")."
        case .untrackedFiles(let count): "\(count) untracked file\(count == 1 ? "" : "s") or folder\(count == 1 ? "" : "s") would be lost."
        case .ignoredFiles(let count, let paths):
            paths.isEmpty
                ? "\(count) ignored file\(count == 1 ? "" : "s") or folder\(count == 1 ? "" : "s") (for example build output or .env) would be lost."
                : "\(count) ignored file\(count == 1 ? "" : "s") or folder\(count == 1 ? "" : "s") would be lost: \(Self.list(paths, total: count))."
        case .disposableIgnoredFiles(let paths):
            "Ignored files you marked as disposable for this repository are deleted with it: \(Self.list(paths))."
        case .submoduleChanges(let count): "\(count) submodule\(count == 1 ? " has" : "s have") local changes."
        case .operationInProgress(let operation): "A \(operation) is in progress in this worktree."
        case .hiddenIndexEntries(let count):
            "\(count) file\(count == 1 ? " is" : "s are") marked skip-worktree or assume-unchanged (or the worktree uses sparse checkout), so Git cannot show whether \(count == 1 ? "it has" : "they have") local changes."
        case .perWorktreeRefs(let refs):
            "The worktree has its own refs that would be deleted with it: \(refs.prefix(5).joined(separator: ", "))\(refs.count > 5 ? ", …" : "")."
        case .nestedGitEntries(let paths):
            "The worktree contains a nested .git folder that Git does not track or show and that would be deleted: \(paths.prefix(5).joined(separator: ", "))\(paths.count > 5 ? ", …" : "")."
        case .headUnavailable(let detail): "The worktree's HEAD could not be read: \(detail)"
        case .headChangedDuringCheck: "HEAD changed while WCleaner was checking this worktree."
        case .notGitHubRepository(let detail): "No usable GitHub remote: \(detail)"
        case .needsAccount: "No connected GitHub account can read this repository."
        case .needsAccountSelection: "Several GitHub accounts can read this repository. Choose one in Settings › Repositories."
        case .accountUnavailable(let detail): "The assigned GitHub account is unavailable: \(detail)"
        case .accountUnverified(let detail): "Repository access could not be verified: \(detail)"
        case .repositoryIdentityMismatch(let detail): "Repository identity does not match: \(detail)"
        case .noPullRequest: "No pull request matches this worktree's branch and HEAD."
        case .pullRequestLookupFailed(let detail): "Pull request status could not be checked: \(detail)"
        case .ambiguousPullRequest(let numbers):
            "Several pull requests match (\(numbers.map { "#\($0)" }.joined(separator: ", "))). Manual review required."
        case .headDiffersFromPullRequest(let local, let pullRequest):
            "Local HEAD \(local.prefix(7)) differs from the pull request head \(pullRequest.prefix(7)); there may be unpublished commits."
        case .pullRequestOpen(let number): "Pull request #\(number) is still open."
        case .pullRequestClosedUnmerged(let number): "Pull request #\(number) was closed without being merged."
        case .pullRequestStateUnknown(let number): "The state of pull request #\(number) could not be determined."
        case .headRepositoryUnverified: "The pull request's head repository could not be verified (it may have been deleted)."
        case .mergedBeforeEnrollment(let date):
            "Merged on \(Self.dateFormatter.format(date)), before this repository was enrolled for cleanup. Review it before WCleaner may remove it."
        case .waitingForDelay(let until): "Eligible for automatic cleanup after \(Self.dateFormatter.format(until))."
        case .cleanupConsentMissing: "You have not enabled worktree removal yet."
        case .automaticCleanupOff: "Automatic cleanup is off (dry run only)."
        case .automaticCleanupPaused: "Automatic cleanup is paused."
        case .deletionDisabledInDevelopmentBuild: "Real removal is disabled in development builds."
        case .anotherCleanupInProgress: "Another cleanup is already running for this repository."
        case .worktreeNoLongerListed: "Git no longer lists this worktree."
        case .expectationChanged(let detail): "The worktree changed since it was checked: \(detail)"
        case .changesStashed(let commit):
            "Its uncommitted changes were saved in Git stash \(commit.prefix(12)). Restore them in any worktree of this repository with “git stash apply \(commit)”."
        case .stashNotConfirmed(let detail):
            "WCleaner could not confirm that Git saved the changes in a stash, so nothing was removed. \(detail) Your changes are still in the worktree or in “git stash list”."
        }
    }

    static let dateFormatter = EnglishDateFormat.dateTime
}

/// English-only date formatting (the UI is English regardless of system language).
public enum EnglishDateFormat {
    public static let dateTime = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "en_US"))
    public static let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_US"))

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        return dateTime.format(date)
    }
}

extension EligibilityReason {
    /// Uncommitted changes that `git stash push --include-untracked` can save completely: staged and unstaged
    /// changes to tracked files and untracked (not ignored) files. Conflicts, submodule changes, hidden index
    /// entries and ignored files are not.
    public var isStashable: Bool {
        switch self {
        case .stagedChanges, .unstagedChanges, .untrackedFiles: true
        default: false
        }
    }

    /// "a, b, c and 4 more"
    public static func list(_ items: [String], total: Int? = nil, limit: Int = 5) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        let remaining = max(total ?? items.count, items.count) - min(items.count, limit)
        return remaining > 0 ? "\(shown) and \(remaining) more" : shown
    }
}
