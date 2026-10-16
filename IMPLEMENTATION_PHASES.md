# Implementation phases

Status as of 2026-10-16, version 0.1.0. "Verified" means covered by automated tests or measured locally; "not verified" items need real credentials or a manual check.

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Xcode project + workspace, Swift package `WCleanerCore`, menu-bar-only app (`LSUIElement`), WC template status icon, test targets | Done, verified |
| 1 | Native status menu, Settings window with top icon toolbar (General, Accounts, Repositories, Auto Cleanup, Notifications, Appearance, History, About), English UI, live System/Light/Dark appearance | Done, verified (app-hosted tests, offscreen renders) |
| 2 | Repository registry (explicit enrollment, canonical paths, deduplication by common Git dir), worktree discovery via `git worktree list --porcelain -z`, local inspection, `du` disk usage with cache | Done, verified on disposable repositories |
| 3 | Multi-account GitHub device flow, `GET /user` identity by host + numeric ID, per-account Keychain items, refresh, Needs Reconnect, Add/Reconnect/Disconnect UI | Implemented and unit-tested with a mocked GitHub. **Not verified against real GitHub**: needs a GitHub App client ID |
| 3B | Repository-to-account resolution: automatic with one eligible account, explicit choice with several, Needs Account with none, no silent fallback, SSH alias resolution | Done, unit-tested |
| 4 | Pull request matching by repository ID, branch, head repository and exact SHA; fork and renamed-branch handling; ambiguity goes to review; status in the menu | Done, unit-tested with a mocked GitHub |
| 5 | Shared polling scheduler (intervals 1–60 min, coalesced Check Now, backoff, rate limits, sleep/wake), persisted merge confirmations and reviews, monitor engine with dry-run decisions | Done, verified |
| 6 | Cleanup executor: consent and settings read live, enrollment re-check, fresh re-verification, deep inspection (ignored files, skip-worktree/assume-unchanged, per-worktree refs, submodules), final status check, `git worktree remove` without `--force`, per-repository serialization, Debug-build removal guard, history. Hardened after an adversarial review (see SECURITY.md) | Done, verified only on disposable temporary repositories |
| 7 | Notifications, Launch at Login (`SMAppService.mainApp`), cleanup history, onboarding, uninstall guide, optional Mole bridge (detect, dry run, confirmed run in Terminal) | Implemented. Notification permission prompts, Login Items registration and Mole Terminal runs were **not exercised** on this machine to avoid changing system state; status reading is implemented |
| 8 | Measurements, documentation, packaging script, Homebrew cask template | Done for local, ad-hoc packaging. Developer ID signing and notarization are scripted but **not run** (no certificate on this machine) |

## Next

1. Register the WCleaner GitHub App and set `WCLEANER_GITHUB_CLIENT_ID` (GITHUB_APP_SETUP.md); then test two real accounts against disposable test repositories, still with a Debug build (no removal).
2. Manual checks of the remaining system integrations: notification permission and delivery, Launch at Login approval states, Mole dry run in Terminal.
3. Release phase: Developer ID certificate, notarization profile, `scripts/release/package.sh --developer-id`, then RELEASING.md.
4. Later: GitLab and GitHub Enterprise hosts (not started).
