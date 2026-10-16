# Releasing

Nothing in this repository publishes automatically. Every step that leaves your Mac (notarization upload, GitHub Release, Homebrew tap) is run by a maintainer, on purpose.

## Prerequisites (not set up yet)

- An Apple Developer Program membership and a **Developer ID Application** certificate in the login keychain (`security find-identity -v -p codesigning`).
- Notarization credentials stored once in the keychain:
  ```sh
  xcrun notarytool store-credentials wcleaner-notary --apple-id <apple id> --team-id <TEAM ID> --password <app-specific password>
  ```
- The public client ID of the WCleaner GitHub App ([GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md)).
- All tests passing: `xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -destination 'platform=macOS' test`.

## 1. Version

Set `MARKETING_VERSION` (for example `0.2.0`) and increase `CURRENT_PROJECT_VERSION` in the WCleaner target build settings.

## 2. Build, sign, notarize, package

```sh
export WCLEANER_DEVELOPMENT_TEAM=ABCDE12345
export WCLEANER_NOTARY_PROFILE=wcleaner-notary
export WCLEANER_GITHUB_CLIENT_ID=Iv23liXXXXXXXXXXXXXX
scripts/release/package.sh --developer-id
```

This archives a universal Release build, exports it with the Developer ID certificate and hardened runtime, notarizes and staples the app, builds `dist/WCleaner-<version>.zip` and a signed, notarized and stapled `dist/WCleaner-<version>.dmg`, and writes SHA-256 checksums. It stops at the first failed check (`codesign --verify`, `stapler validate`, `spctl --assess`).

For a local smoke test without any Apple credentials:

```sh
scripts/release/package.sh --adhoc     # dist/WCleaner-<version>-adhoc.{zip,dmg}: ad-hoc signed, NOT notarized
```

Ad-hoc packages are for testing on the build machine only. Never publish them.

## 3. Verify by hand

On a second Mac (or a fresh user account): open the DMG, drag WCleaner to Applications, launch it, and check that Gatekeeper opens it without warnings, that there is no Dock icon, that Settings › Accounts says sign-in is available, and that Launch at Login reports *On* after enabling it.

## 4. Publish (manual)

1. Tag: `git tag -s v<version> -m "WCleaner <version>" && git push origin v<version>`.
2. Create a GitHub Release for the tag and attach the DMG, the ZIP and the `.sha256` file. Describe user-visible changes and any safety-relevant changes.
3. Optional Homebrew cask: copy `packaging/homebrew/wcleaner.rb` to the `alhamsya/homebrew-tap` repository as `Casks/wcleaner.rb`, set `version` and the DMG `sha256`, run `brew audit --cask --new wcleaner` and `brew install --cask wcleaner` locally, then open a pull request on the tap.

`brew uninstall --cask wcleaner` quits the app and removes it; `brew uninstall --zap --cask wcleaner` also removes WCleaner's settings and history. Keychain tokens are removed by disconnecting accounts in the app first.
