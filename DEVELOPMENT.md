# Development runbook

## Environment

Verified with: Apple M1, macOS 14.8.3 (23J220), Xcode 16.2 (16C5032a), Swift 6.0.3, Git 2.39.5 (Apple Git-154).

```sh
xcodebuild -version && swift --version && git --version && uname -m
```

## Layout

| Path | Contents |
| --- | --- |
| `WCleaner/` | AppKit app: status item and menu, Settings window and panes, dialogs, notifications, Launch at Login, Terminal launcher. |
| `Packages/WCleanerCore/` | Swift package with all logic: Git process runner and parsers, repository registry, disk usage, GitHub API and device flow, Keychain, account resolution, PR matching, scheduler, eligibility evaluator, cleanup executor, history, Mole detection. |
| `WCleanerTests/` | App-hosted tests (menu, Settings window, appearance, coordinator). |
| `Config/` | `WCleaner.xcconfig`, `Info.plist` additions, `Local.xcconfig.example`. |
| `scripts/` | `release/package.sh` (packaging, never publishes), `measure-idle.sh`. |
| `packaging/homebrew/` | Cask template (not published). |

New source files are picked up automatically (Xcode 16 synchronized folders); no project edits needed.

## Configuration

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # gitignored
```

- `WCLEANER_GITHUB_CLIENT_ID`: public client ID of your GitHub App (see [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)). Empty means the Accounts pane shows "not configured" and no account can be added. Never put a client secret or private key anywhere; WCleaner does not use them.
- `WCLEANER_BUNDLE_IDENTIFIER`: optional, to keep a development copy separate from a release copy.
- `WCLEANER_CODE_SIGN_IDENTITY` / `WCLEANER_DEVELOPMENT_TEAM`: release only. Debug builds are ad-hoc signed.

## Build and test

Always use the workspace: it is what makes the scheme run the package tests too.

```sh
# Everything: core package tests + app-hosted tests
xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=arm64' test

# Core package only (fast)
cd Packages/WCleanerCore && swift test

# One test class
swift test --filter CleanupExecutorTests

# Debug app
xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=arm64' build
open build/DerivedData/Build/Products/Debug/WCleaner.app
```

Optional, touches the real login Keychain (creates and deletes one test item):

```sh
cd Packages/WCleanerCore && WCLEANER_KEYCHAIN_TESTS=1 swift test --filter KeychainCredentialStoreTests
```

## Safeguards for real data

These are enforced in code; keep them when changing anything:

- **Debug builds never remove worktrees.** `AppCoordinator.makeDeletionPolicy` disables removal unless the environment has `WCLEANER_ALLOW_REMOVAL_IN_DEBUG=1`. The Auto Cleanup pane says so. Only set it when every enrolled repository is a disposable test repository.
- **Tests never touch real repositories.** Destructive tests use `TemporaryGitRepository`, which creates `WCleanerTests-<UUID>` under the system temporary directory, refuses to operate elsewhere, isolates Git from your global config (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`) and deletes the folder afterwards. Check for leftovers with:
  ```sh
  ls -d "$(getconf DARWIN_USER_TEMP_DIR)"WCleanerTests-* 2>/dev/null | wc -l   # expect 0
  ```
- **The test host starts no services.** Inside XCTest, `AppCoordinator.start()` skips Git, the data folder, GitHub and the scheduler (regression test: `testStartInsideTestHostStartsNoBackgroundServices`). Use `startInterface()` in UI tests.
- **No network in tests.** GitHub traffic goes through `MockHTTPTransport`; time and sleeping are injected.
- A separate development copy: set `WCLEANER_BUNDLE_IDENTIFIER` in `Local.xcconfig` so its settings and Keychain items stay apart from a release install. Data lives in `~/Library/Application Support/WCleaner` and `defaults read <bundle id>`.

## Manual test plan

1. Launch the Debug build: no Dock icon, WC icon in the menu bar, welcome window on first launch.
2. Settings: the toolbar shows General, Accounts, Repositories, Auto Cleanup, Notifications, Appearance, History, About. Switching Appearance applies immediately and survives relaunch.
3. Add a **disposable** repository (create one with a couple of `git worktree add` worktrees in `/tmp`). The menu lists its linked worktrees with sizes marked as estimates and decisions with reasons.
4. With a configured client ID: Accounts › Add Account… shows the device code; after approving on GitHub the account shows *Connected* with its login. Add a second account; reconnect and disconnect each independently.
5. Auto Cleanup stays a dry run until *Allow Worktree Removal…* is accepted; in Debug builds it stays a dry run anyway.

## Measuring performance

```sh
open build/DerivedData/Build/Products/Release/WCleaner.app
sleep 15 && scripts/measure-idle.sh 120
```

The script samples `ps` (CPU time, RSS), `footprint` and `top` (idle wakeups). `ps` CPU time covers the app process only; Git and `du` run as short-lived child processes.

Last measurement (Apple M1, 8 GB, macOS 14.8.3, Release build 0.1.0, universal binary):

| Scenario | Result |
| --- | --- |
| Idle, no repositories or accounts, 120 s window | 0.00 s CPU time added; RSS ≈ 9.9 MB; phys_footprint 8.5 MB (peak 8.9 MB); 0 idle wakeups in a 30 s `top` sample |
| 1 disposable repository with 20 clean worktrees, no account, 1-minute interval, 180 s window | 0.11 s CPU over 3 minutes (≈0.05–0.06 s per scan in the app process, ≈0.06% of one core on average); RSS 14–24 MB (higher right after launch); phys_footprint 9.0 MB |
| Git work of one such scan, replayed outside the app (`/usr/bin/time`, 3 runs) | 0.48–0.75 s wall time, ≈0.01 s user+sys CPU (mostly process start-up) |
| Nested `.git` folder scan (`NestedGitScanner`, `-O` build, generated tree with 50,000 files in 1,250 folders, warm file cache, 3 runs; measured after the release build above) | 0.19–0.21 s per worktree. It runs only for worktrees that look removable (in a scan, after a settings change, and twice in the executor). Without accounts, as in the 20-worktree row, it never runs |
| App size | 12 MB bundle; 8.0 MB universal executable (arm64 + x86_64, not stripped); 3.4 MB asset catalog |

Not measured yet: scans with GitHub accounts and network latency, very large repositories, menu opening latency, startup time.

## Troubleshooting

- *Git not found*: WCleaner needs Git 2.36+. It avoids `/usr/bin/git` when no developer tools are installed (it would pop up an installer); install Command Line Tools (`xcode-select --install`) or Homebrew Git.
- *"Scheme WCleanerCore is not currently configured for the test action"*: use `-workspace WCleaner.xcworkspace`, not the project.
- Reset a development install: quit WCleaner, then `defaults delete io.github.alhamsya.WCleaner` and remove `~/Library/Application Support/WCleaner`. Disconnect accounts first to delete their Keychain items.
