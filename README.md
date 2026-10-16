# WCleaner

WCleaner is a small native macOS menu bar app. It finds the Git **linked worktrees** of the repositories you add, matches each one to its GitHub pull request, and can carefully remove worktrees whose pull requests are verifiably merged.

- Native AppKit, Swift 6 (strict concurrency), macOS 14 Sonoma or later. Apple frameworks only; no Electron, web views, helpers or daemons.
- Menu bar only (no Dock icon). English UI with System, Light and Dark appearance.
- Several GitHub.com accounts at once, each signed in with GitHub's device flow and stored in its own Keychain item.
- Dry run by default. WCleaner removes nothing until you allow it, and then only after fresh safety checks.

> **Status: 0.1.0, pre-release, not published.** No signed build, DMG or Homebrew cask has been released. GitHub sign-in works only in builds configured with a GitHub App client ID ([GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)). End-to-end use against real GitHub accounts has not been verified yet.

## What it does

- **Repositories:** you add repositories explicitly. WCleaner lists their worktrees with `git worktree list --porcelain -z`, shows branch, HEAD, pull request state and estimated size (`du`, cached for about an hour, always labeled as an estimate).
- **Accounts:** each repository is matched to a verified GitHub account. With exactly one account that can see the repository it is assigned automatically; with several you choose; with none it shows *Needs Account*. WCleaner never silently switches accounts.
- **Pull requests:** matched by repository ID, branch, head repository and exact head commit. Only `merged_at` counts as merged; closed-but-unmerged and ambiguous matches are never cleaned.
- **Checks:** every 1, 5, 10, 15 (default), 30 or 60 minutes with one shared scheduler, backoff on errors, rate-limit awareness, no checks during sleep and no catch-up bursts after wake.
- **Cleanup:** off until you consent. Optional delay of 0 minutes to 1 day. The delay starts once the worktree has passed every check. Pull requests merged before you enrolled a repository always need an individual review.
- **Also:** notifications (respecting macOS permission), Launch at Login (`SMAppService`), a local non-secret cleanup history, an uninstall guide, and an optional bridge to [Mole](https://github.com/tw93/Mole) (see below).

## Safety rules

A linked worktree is removed only when **all** of these hold, re-checked immediately before removal with fresh data from Git and GitHub:

1. It is a linked worktree of an enrolled repository: not the primary worktree, not bare, locked, prunable, detached, nested, symlinked or otherwise ambiguous.
2. It has no staged, unstaged, untracked or **ignored** files. It has no files flagged skip-worktree or assume-unchanged, no refs that exist only in that worktree, no nested folders named `.git`, and no submodules. No merge, rebase, cherry-pick, revert or bisect is in progress.
3. Its HEAD is exactly the pull request's head commit, so there are no unpublished local commits.
4. The repository identity, account, pull request and merge are verified. Any `401`, `403`, `404`, network error or rate limit blocks cleanup.
5. The merge happened after enrollment and consent, or you reviewed that exact pull request and commit.
6. Consent is still given and, for automatic cleanup, cleanup is still on and not paused. These settings are read again right before removal.

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
