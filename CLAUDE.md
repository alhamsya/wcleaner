# WCleaner: notes for coding agents

Native macOS 14+ menu bar app (AppKit, Swift 6 strict concurrency). Logic lives in `Packages/WCleanerCore`; the app in `WCleaner/`. See DEVELOPMENT.md for commands.

## Non-negotiable safety rules

- Never run WCleaner's cleanup, or any `git worktree remove`, against a real repository. Destructive tests use `TemporaryGitRepository` (temp dir, isolated Git config, deleted afterwards). Check that `"$(getconf DARWIN_USER_TEMP_DIR)"WCleanerTests-*` is empty after test runs.
- Worktree removal goes only through `CleanupExecutor` → `GitClient.removeWorktree` (`git worktree remove -- <path>`, never `--force`, never retried). Do not add `rm`, `git clean`, branch deletion, prune or force options.
- The only other command that changes a worktree is `GitClient.stashPush` (`git stash push --include-untracked`, hooks off), run by the executor only for a user-confirmed *Save Changes and Remove* (`CleanupMode.manualStashed`), only after every other local check passed, and the stash must be confirmed (new, carrying the attempt's token, based on HEAD) before removal. Never `--all`, never `stash drop`/`pop`/`clear`, never automatic.
- The eligibility evaluator fails closed. Any new uncertainty must become a blocking `EligibilityReason`, never a default "eligible".
- Debug builds must keep removal disabled unless `WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1`. The test host must not start background services (`AppCoordinator.start()` checks `AppEnvironment.isRunningUnitTests`; UI tests call `startInterface()`).
- Tokens only in the Keychain; never log, persist or show them. No client secrets or private keys. No network access in tests (`MockHTTPTransport`).
- Mole is third-party GPL-3.0: never bundle its code; only detect it and run it visibly in Terminal, dry run first.

## Commands

```sh
xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' test
cd Packages/WCleanerCore && swift test
```

Use `/usr/bin/git` and `/usr/bin/grep` in scripts when a shell wrapper rewrites those commands.
