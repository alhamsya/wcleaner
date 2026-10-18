# WCleaner

WCleaner is a small native macOS menu bar app. It finds the Git **linked worktrees** of the repositories you add, matches each one to its GitHub pull request, and can carefully remove worktrees whose pull requests are verifiably merged.

- Native AppKit, Swift 6 (strict concurrency), macOS 14 Sonoma or later. Apple frameworks only; no Electron, web views, helpers or daemons.
- Menu bar only (no Dock icon). English UI with System, Light and Dark appearance.
- Several GitHub.com accounts at once, each signed in with GitHub's device flow and stored in its own Keychain item, or borrowed from an existing GitHub CLI (`gh`) login for organizations where the WCleaner GitHub App is not installed.
- Dry run by default. WCleaner removes nothing until you allow it, and then only after fresh safety checks.

> **Status: 0.1.0, pre-release, not published.** No signed build, DMG or Homebrew cask has been released. GitHub sign-in works only in builds configured with a GitHub App client ID ([GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)). End-to-end use against real GitHub accounts has not been verified yet.

## What it does

- **Menu:** a summary card (last check, total size, how much passed every safety check, counts per status) above colour-coded worktree rows with their pull request (merged purple, open green, closed red) and size. The menu bar icon shows a short sweep while WCleaner checks and a sparkle after a cleanup; with Reduce Motion it stays still. Each worktree links to its pull request, from the menu and from Settings › Auto Cleanup.
- **Disposable ignored files:** off by default, so any ignored file keeps a worktree. Per repository you can list exact paths, such as build output or caches, that may be deleted with a worktree. Set them in Settings › Repositories, or choose *Allow Deleting These Ignored Files…* in a worktree's menu to approve exactly the paths Git reported there.
- **Repositories:** you add repositories explicitly. WCleaner lists their worktrees with `git worktree list --porcelain -z`, shows branch, HEAD, pull request state and estimated size (`du`, cached for about an hour, always labeled as an estimate).
- **Accounts:** each repository is matched to a verified GitHub account. With exactly one account that can see the repository it is assigned automatically; with several you choose; with none it shows *Needs Account*. WCleaner never silently switches accounts.
- **Pull requests:** matched by repository ID, branch, head repository and exact head commit. Only `merged_at` counts as merged; closed-but-unmerged and ambiguous matches are never cleaned.
- **Checks:** every 1, 5, 10, 15 (default), 30 or 60 minutes with one shared scheduler, backoff on errors, rate-limit awareness, no checks during sleep and no catch-up bursts after wake.
- **Cleanup:** off until you consent. Optional delay of 0 minutes to 1 day. The delay starts once the worktree has passed every check. Pull requests merged before you enrolled a repository always need an individual review.
- **Also:** notifications (respecting macOS permission), Launch at Login (`SMAppService`), a local non-secret cleanup history, an uninstall guide, and an optional bridge to [Mole](https://github.com/tw93/Mole) (see below).

## Safety rules

A linked worktree is removed only when **all** of these hold, re-checked immediately before removal with fresh data from Git and GitHub:

1. It is a linked worktree of an enrolled repository: not the primary worktree, not bare, locked, prunable, detached, nested, symlinked or otherwise ambiguous.
2. It has no staged, unstaged or untracked files, and no **ignored** files except in paths you marked as disposable for that repository (for example `build` or `node_modules`). It has no files flagged skip-worktree or assume-unchanged, no refs that exist only in that worktree, no nested folders named `.git`, and no checked-out submodules. A submodule that was never checked out is an empty folder and does not block. No merge, rebase, cherry-pick, revert or bisect is in progress.
3. Its HEAD is exactly the pull request's head commit, so there are no unpublished local commits.
4. The repository identity, account, pull request and merge are verified. Any `401`, `403`, `404`, network error or rate limit blocks cleanup.
5. The merge happened after enrollment and consent, or you reviewed that exact pull request and commit.
6. Consent is still given and, for automatic cleanup, cleanup is still on and not paused. These settings are read again right before removal.

**Remove Worktree Anyway** (manual only): a worktree whose pull request is open, closed, missing or cannot be verified can still be removed from its menu, as long as rules 1, 2 and 6 hold (nothing local would be lost) and you confirm. Git keeps the branch and all its commits, including commits that were never pushed. Automatic cleanup never does this; it still needs a verified merge.

**Save Changes and Remove Worktree** (manual only): when uncommitted changes are the only thing keeping a worktree (staged, unstaged or untracked files), WCleaner can save them in a Git stash first (`git stash push --include-untracked`), confirm that the stash holds them, and only then remove the worktree. The stash lives in the repository, so you can restore the changes later in any worktree with `git stash apply <stash>`; WCleaner shows the exact command and keeps it in History. Ignored files (unless marked disposable), merge conflicts, submodule changes and skip-worktree files still keep a worktree.

Removal is `git worktree remove -- <path>`, **without `--force`**. If Git refuses, WCleaner stops and records why. It never uses `rm -rf`, `git clean`, branch deletion or force-prune. Cleanups are serialized per repository. Development (Debug) builds never remove anything unless `WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1` is set. See [SECURITY.md](SECURITY.md).

## Build from source

Requirements: macOS 14+, Xcode 16 (Swift 6), Git 2.36+.

```sh
git clone https://github.com/alhamsya/wcleaner.git
cd wcleaner
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set WCLEANER_GITHUB_CLIENT_ID
xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -configuration Release \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/WCleaner.app
```

Tests, the development runbook and real-data safeguards are in [DEVELOPMENT.md](DEVELOPMENT.md). Release packaging (no publishing) is in [RELEASING.md](RELEASING.md).

## Mole (optional)

If you have installed [Mole](https://github.com/tw93/Mole) (`mo`, GPL-3.0) yourself, Settings › General can open it in Terminal, run `mo clean --dry-run`, and, only after that preview and a separate confirmation, run `mo clean` in a visible Terminal window. WCleaner does not include, bundle or link any Mole code.

## Uninstall

WCleaner never deletes itself. Settings › About › *Uninstall Guide* explains the steps: turn off Launch at Login, disconnect accounts (removes Keychain tokens), quit, move the app to the Trash (or `brew uninstall --cask wcleaner` once a cask exists), and optionally remove `~/Library/Application Support/WCleaner` and its preferences.

## License

MIT. See [LICENSE](LICENSE). Branding assets are described in [assets/branding/README.md](assets/branding/README.md).
