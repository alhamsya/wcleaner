# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's **Report a vulnerability** (Security tab of `alhamsya/wcleaner`) rather than in a public issue. Include the WCleaner version, macOS version and steps to reproduce.

## Threat model in brief

WCleaner deletes folders, so the main risk is **removing work that was not safe to remove**. Everything is designed to fail closed: when anything is unknown, the answer is "don't remove".

### Removal

- Removal happens only after explicit consent (Settings › Auto Cleanup › *Allow Worktree Removal…*). Automatic cleanup is a second, separate switch, and can be paused.
- Immediately before every removal (`CleanupExecutor`), WCleaner re-runs everything without caches. It:
  - checks that the repository is still enrolled with the same record;
  - lists worktrees again;
  - deep-inspects the worktree:
    - status, including **ignored** files. Each ignored file must lie in a path you marked as disposable for that repository (see below), or the worktree is kept;
    - files flagged *skip-worktree* or *assume-unchanged*, whose changes `git status` hides;
    - refs that exist only in this worktree (`refs/worktree`, `refs/bisect`, `refs/rewritten`);
    - files or folders named `.git` (in any letter case) below the top level. `git status` never shows them, and `git worktree remove` deletes them;
    - submodules: submodule repositories in the worktree's own Git folder (`modules/`) block removal, and so does any submodule folder that holds anything (files, a `.git` entry, a symbolic link, or content that cannot be read). A submodule that was never checked out is an empty folder and does not block. `.gitmodules` alone does not block;
    - in-progress operations;
    - the `.git` file back-pointer and symlinks;
  - verifies the existing account assignment without discovering or assigning a new one;
  - fetches the pull request again, bypassing ETags.
- **Disposable ignored files** are opt-in per repository, set in Settings › Repositories or from a worktree's menu (*Allow Deleting These Ignored Files…*, which lists the exact paths Git reported). Entries are exact paths relative to the worktree's top folder, with no wildcards, `..` or `.git`. An entry covers that file or folder and everything inside it, nothing else. Ignored files are listed with `git status --ignored=matching`, which reports exactly what an ignore rule matched rather than a parent folder that happens to hold only ignored files. If Git reports more than 500 ignored entries, the ones beyond the list count as not disposable. The final check before removal reads the repository's list as it is at that moment.
- **Removal without a merged pull request** (*Remove Worktree Anyway…*) is manual only and needs consent and a confirmation. It waives only the pull request, account and merge-timing rules. Every structural and local check above still runs, with the deep checks, before and again right before removal, and the request is bound to the HEAD shown in the confirmation. Git keeps the branch and its commits; commits that were never pushed then exist only in that local branch. Automatic cleanup never uses this path.
- **Save Changes and Remove** (manual only, consent and confirmation required) is the only feature that changes a worktree before removing it. It is offered only when staged, unstaged or untracked changes are the sole local reason. Right before it, every other local check runs again (deep); then `git stash push --include-untracked --message "WCleaner <token>: …"` runs with hooks, fsmonitor and the untracked cache turned off. WCleaner then confirms that `refs/stash` points to a new stash with that token, made on the worktree's HEAD, with an untracked-files commit when there were untracked files. Only then does the normal removal path run, with every local check twice. Ignored files are never stashed or touched by the stash, and WCleaner never uses `--all`, `stash drop`, `stash pop` or `stash clear`. The stash commit is recorded in History, and any refusal after the stash says where the changes are.
- It reads the settings again at each step. If you pause or turn off automatic cleanup, or withdraw consent, a removal that is already under way stops.
- Right before `git worktree remove`, every local check runs once more. Git's own check covers none of the deep checks above, and it ignores ignored files.
- The dry run in the menu runs the same deep checks for every worktree that looks removable. A worktree shown as *Safe to remove* is therefore not refused for a reason the menu did not show.
- It removes only paths Git lists for an enrolled repository, only via `git worktree remove -- <path>` and never with `--force`. A Git refusal is recorded and never retried. Apart from deleting its own data files (for example when you clear the history), WCleaner contains no file-deletion code, and it never runs `rm`, `git clean`, branch deletion or `git worktree prune`.
- The worktree's HEAD must equal the merged pull request's head commit, so unpublished commits block removal. The branch itself and its commits are left in the repository.
- Pull requests merged before the repository was enrolled (or before consent) need a per-worktree review, bound to that pull request number and head commit. Merges up to 15 minutes after enrollment also need a review, in case this Mac's clock was behind GitHub's.
- Review and removal dialogs are bound to the pull request and commit they showed. If either changed before you confirm, nothing happens.
- The cleanup delay is a grace period. It starts when the worktree first passes every check, and restarts when new local content appears.
- Cleanups are serialized per repository; scans, reviews and removals never interleave.
- Debug builds cannot remove anything unless `WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1` is set.

### Credentials

- GitHub tokens are stored only in the macOS Keychain, one item per account and token type, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. They are never written to settings, logs, history or notifications; token types print as `<redacted>`.
- No client secret or private key exists in the app. Sign-in uses the public-client device flow.
- Optional *GitHub CLI login*: for such an account WCleaner stores no token at all. When it needs one it runs `gh auth token --hostname github.com --user <login>` (discrete arguments, allow-listed environment without `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST` or `GH_CONFIG_DIR`, 10 s timeout), keeps the token in memory for at most 5 minutes, and checks every freshly read token with `GET /user`: a token for a different user ID, a missing `gh` or a logged-out `gh` marks the account *Needs Reconnect*. Disconnecting never logs `gh` out. Trade-off: GitHub CLI tokens usually carry the broad `repo` scope (read and write); WCleaner only sends `GET` requests, but anyone who can run code as you can already read that token from `gh`.
- Each account is identified by host and numeric user ID. Reconnecting with a different user is rejected. A repository never falls back to another account silently.
- Network: only `github.com` and `api.github.com` over HTTPS (TLS 1.2+), using an ephemeral `URLSession` with no cookies or disk cache. Redirects are followed only to the same host over HTTPS, so the `Authorization` header never reaches another host. URL path segments are strictly validated and percent-encoded.
- `401` marks the account *Needs Reconnect*; `403`, `404`, `422`, rate limits and network errors block cleanup for that scan.

### Local processes

- Git, `du` and (for GitHub CLI accounts) `gh auth status` / `gh auth token` run through `Process` with discrete arguments (no shell), a minimal environment (`GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, fixed `PATH`, no pager, `core.fsmonitor=false` for status), timeouts and output limits. SSH host aliases are resolved by reading `~/.ssh/config`, never by running `ssh`.
- `du` uses `-x -P`: one filesystem, no symlink following. Sizes are estimates.
- Remote URLs are shown with embedded credentials redacted.

### Data on disk

`~/Library/Application Support/WCleaner` (folder `0700`, files `0600`): repositories, account metadata, assignments, per-worktree tracking, and `cleanup-history.jsonl` (time, repository, worktree path, branch, commit, pull request, account login and ID, reasons, result). No tokens. Preferences are in `defaults` under the bundle identifier.

### Optional Mole integration

Mole is a separate GPL-3.0 tool that the user installs. WCleaner only detects it (`mo --version`) and writes a self-deleting script to a private temporary folder that Terminal runs visibly. A cleanup is offered only after a dry-run preview in the same session, plus its own confirmation.

## Known limitations

- The app is not sandboxed: it must run Git and `du` on folders you choose. It is hardened-runtime signed in Release builds.
- A worktree could still change in the moment between the final status check and Git's removal. Git's own refusal to remove dirty worktrees without `--force` is the last line of defense, but it does not cover ignored files created in that moment.
- Commits that exist **only in the worktree's HEAD reflog** (for example, a commit you amended or reset away) are not checked and are lost with the worktree's administrative folder. Blocking on them would block every amend or rebase workflow. Commits on branches are never affected, because the branch is kept.
- Ignored files are detected with `git status --ignored=matching` (with fsmonitor and the untracked cache turned off). Ignored files inside a path you marked as disposable are deleted with the worktree and cannot be recovered, including files that appear there later. Folders named `.git` are found by WCleaner's own folder scan. That scan does not follow symbolic links, and it fails closed above 2 million entries or 60 seconds.
- Sparse checkouts are always kept, because their skip-worktree entries cannot be checked.
- The review requirement for pre-enrollment merges allows for 15 minutes of clock difference between this Mac and GitHub. If the Mac's clock was further behind when you enrolled a repository, an older merge might not be flagged for review. Every other check still applies.
- Tested only with GitHub.com; GitHub Enterprise and GitLab are not supported.
