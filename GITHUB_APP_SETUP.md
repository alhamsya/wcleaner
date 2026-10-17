# GitHub sign-in setup

WCleaner signs in with GitHub's **device flow**: it shows a short code, you enter it on github.com, and GitHub returns a token. The flow needs only a public **client ID**. WCleaner never uses or stores a client secret or a GitHub App private key, and none must be added to the build.

A build without a client ID shows "GitHub sign-in is not configured" in Settings › Accounts and cannot connect any account. Nothing pretends to be signed in.

## 1. Register a GitHub App (recommended)

A GitHub App gives read-only, fine-grained access, unlike an OAuth App's broad `repo` scope.

1. github.com › your profile picture › **Settings** › **Developer settings** › **GitHub Apps** › **New GitHub App**. For an organization-owned app, use the organization's settings instead.
2. **GitHub App name**: for example `WCleaner (yourname)`. **Homepage URL**: `https://github.com/alhamsya/wcleaner` or your fork.
3. **Identifying and authorizing users**: check **Enable Device Flow**. Leave the callback URL empty and leave "Request user authorization (OAuth) during installation" unchecked.
4. **Webhook**: uncheck **Active** (WCleaner polls; it receives no webhooks).
5. **Repository permissions**:
   - **Pull requests: Read-only** (required: list pull requests, pull requests for a commit, get a pull request).
   - **Metadata: Read-only** (mandatory and selected automatically: repository identity and fork information).
   - Nothing else. WCleaner never writes to GitHub.
6. **Account permissions**: none. (`GET /user`, used to verify who signed in, needs no permission.)
7. **Where can this GitHub App be installed?**: *Only on this account* for personal use, or *Any account* if others will use your build.
8. Create the app and copy its **Client ID** (it starts with `Iv`). Do **not** generate a client secret or private key for WCleaner.

### Install the app where your repositories live

A GitHub App user token can reach only repositories where the app is **installed**, and only what both you and the app may access. Install the app (app page › **Install App**) on your user account and on each organization whose repositories you add, choosing *All repositories* or the specific ones. Organizations may require an owner's approval.

If a repository shows *Needs Account* or "no access" although you can see it on github.com, the app is usually not installed for that owner. If you cannot install it there (for example in an organization you do not own), use a GitHub CLI login instead (below).

### Token expiration

By default GitHub App user tokens expire after 8 hours and come with a refresh token valid for 6 months. WCleaner renews tokens automatically shortly before they expire. GitHub documents that refreshing a device-flow token does not require a client secret. If a refresh fails (for example after 6 months), the account shows **Needs Reconnect** and stops being used until you reconnect it; other accounts are unaffected. GitHub recommends keeping expiration on (app settings › **Optional features** › *User-to-server token expiration*).

## 2. Put the client ID into the build

The client ID is public, but keep it out of the shared config so forks use their own:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # gitignored
# edit Config/Local.xcconfig:
WCLEANER_GITHUB_CLIENT_ID = Iv23liXXXXXXXXXXXXXX
```

Or pass it on the command line: `xcodebuild … WCLEANER_GITHUB_CLIENT_ID=Iv23li… build`, or `WCLEANER_GITHUB_CLIENT_ID=… scripts/release/package.sh --adhoc`.

The value ends up in the app's `Info.plist` as `WCGitHubClientID`. Check with:

```sh
/usr/bin/plutil -p build/DerivedData/Build/Products/Debug/WCleaner.app/Contents/Info.plist | grep WCGitHubClientID
```

## 3. Connect accounts

Settings › **Accounts** › **Add Account…** shows a code. Click **Open GitHub**, enter the code, approve. WCleaner then calls `GET /user` and shows the account as **Connected** with its login. Repeat for more accounts; signing in again with the same account updates it instead of adding a duplicate. **Reconnect…** must be done with the same GitHub user. **Disconnect…** deletes only that account's Keychain items.

Repository assignment: when exactly one connected account can read a repository it is assigned automatically; with several you pick one in Settings › Repositories; if the assigned account later loses access or is disconnected, the repository shows *Account Unavailable* and is not cleaned until you choose again.

## Alternative: GitHub CLI login (no app installation needed)

If [GitHub CLI](https://cli.github.com) is installed (`/opt/homebrew/bin/gh` or `/usr/local/bin/gh`) and logged in (`gh auth login`), Settings › Accounts › **Use GitHub CLI Login…** lists its GitHub.com accounts. Pick one and WCleaner:

- verifies it with `GET /user` and shows it as **Connected** (Token column: *From GitHub CLI*);
- stores **no** token: it runs `gh auth token --hostname github.com --user <login>` when it checks, keeps the token in memory for up to 5 minutes, and re-checks the user ID each time it reads a new one;
- reaches every repository that GitHub CLI can reach, including organization repositories where the WCleaner GitHub App is not installed (GitHub CLI is usually already authorized there).

This works even in builds without a client ID. GitHub CLI tokens normally have the `repo` scope (read **and** write); WCleaner only reads. If you run `gh auth logout`, or `gh` starts returning a token for a different user, the account shows **Needs Reconnect**. **Disconnect…** only removes WCleaner's record; GitHub CLI stays logged in. Signing in to the same GitHub user with the device flow later switches the account back (and vice versa; switching to GitHub CLI deletes that account's WCleaner Keychain items).

## Alternative: OAuth App

An OAuth App with **Enable Device Flow** also works (client ID without the `Iv` prefix). WCleaner then requests the `repo` scope, which grants read **and write** access to all your private repositories. That is broader than WCleaner needs, so prefer a GitHub App.

## What is stored where

| Data | Location |
| --- | --- |
| Access token, refresh token | macOS Keychain, one generic-password item per account and token type (services `<bundle id>.github.access-token` / `.refresh-token`), this device only, not synced |
| Account login, numeric user ID, token expiry dates, token source (device flow or GitHub CLI) | `~/Library/Application Support/WCleaner/accounts.json` (no secrets) |
| GitHub CLI account tokens | Not stored by WCleaner; read from `gh` when needed and kept in memory for up to 5 minutes |
| Repository-to-account assignments | `~/Library/Application Support/WCleaner/account-mappings.json` |

Network access goes only to `https://github.com` (device flow) and `https://api.github.com` (REST API version 2022-11-28).
