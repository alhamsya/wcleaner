#!/bin/zsh
# Builds release artifacts for WCleaner. It never uploads, tags, or publishes anything.
#
#   scripts/release/package.sh --adhoc
#       Local test package: Release build, ad-hoc signature, NOT notarized.
#       Output: dist/WCleaner-<version>-adhoc.zip and .dmg (for testing on this Mac only).
#
#   scripts/release/package.sh --developer-id
#       Distribution package: archive, Developer ID signature, notarization, stapling, DMG and ZIP.
#       Requires (environment variables, never committed):
#         WCLEANER_DEVELOPMENT_TEAM   Apple Developer team ID, e.g. ABCDE12345
#         WCLEANER_NOTARY_PROFILE     Keychain profile created with `xcrun notarytool store-credentials`
#         WCLEANER_GITHUB_CLIENT_ID   Public client ID of the WCleaner GitHub App (optional but recommended)
#       and a "Developer ID Application" certificate in the login keychain.
#
# Publishing (GitHub Releases, Homebrew tap) is a separate, manual step described in RELEASING.md.
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"

MODE=${1:-}
if [[ "$MODE" != "--adhoc" && "$MODE" != "--developer-id" ]]; then
  print -u2 "Usage: $0 --adhoc | --developer-id"
  exit 64
fi

BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
APP_NAME="WCleaner"
mkdir -p "$BUILD" "$DIST"

common_settings=()
if [[ -n "${WCLEANER_GITHUB_CLIENT_ID:-}" ]]; then
  common_settings+=("WCLEANER_GITHUB_CLIENT_ID=$WCLEANER_GITHUB_CLIENT_ID")
fi

version() {
  /usr/bin/defaults read "$1/Contents/Info.plist" CFBundleShortVersionString
}

make_zip() {
  local app=$1 zip=$2
  rm -f "$zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
}

make_dmg() {
  local app=$1 dmg=$2 staging
  staging=$(mktemp -d "$BUILD/dmg.XXXXXX")
  /usr/bin/ditto "$app" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$dmg"
  /usr/bin/hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
  rm -rf -- "$staging"
}

checksums() {
  (cd "$DIST" && /usr/bin/shasum -a 256 "$@" > "${1%.*}.sha256")
}

if [[ "$MODE" == "--adhoc" ]]; then
  LOG="$BUILD/adhoc-build.log"
  if ! xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -configuration Release \
    -derivedDataPath "$BUILD/DerivedData" -destination 'generic/platform=macOS' \
    "${common_settings[@]}" build > "$LOG" 2>&1; then
    /usr/bin/grep -E "error:" "$LOG" | head -20
    print -u2 "Build failed; see $LOG"
    exit 1
  fi
  APP="$BUILD/DerivedData/Build/Products/Release/$APP_NAME.app"
  /usr/bin/codesign --verify --strict --verbose=2 "$APP"
  VERSION=$(version "$APP")
  ZIP="$DIST/$APP_NAME-$VERSION-adhoc.zip"
  DMG="$DIST/$APP_NAME-$VERSION-adhoc.dmg"
  make_zip "$APP" "$ZIP"
  make_dmg "$APP" "$DMG"
  checksums "${ZIP:t}" "${DMG:t}"
  print "Ad-hoc package (not Developer ID signed, not notarized; for local testing only):"
  print "  $ZIP"
  print "  $DMG"
  exit 0
fi

: "${WCLEANER_DEVELOPMENT_TEAM:?Set WCLEANER_DEVELOPMENT_TEAM to your Apple Developer team ID}"
: "${WCLEANER_NOTARY_PROFILE:?Set WCLEANER_NOTARY_PROFILE (see xcrun notarytool store-credentials)}"
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q "Developer ID Application"; then
  print -u2 "No \"Developer ID Application\" signing identity found in the keychain."
  exit 1
fi
if [[ -z "${WCLEANER_GITHUB_CLIENT_ID:-}" ]]; then
  print -u2 "Warning: WCLEANER_GITHUB_CLIENT_ID is empty; the release will show GitHub sign-in as not configured."
fi

ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
rm -rf -- "$ARCHIVE" "$EXPORT"

xcodebuild -workspace WCleaner.xcworkspace -scheme WCleaner -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  WCLEANER_CODE_SIGN_IDENTITY="Developer ID Application" \
  WCLEANER_DEVELOPMENT_TEAM="$WCLEANER_DEVELOPMENT_TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  "${common_settings[@]}" archive

EXPORT_OPTIONS="$BUILD/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$WCLEANER_DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT/$APP_NAME.app"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"
/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 | /usr/bin/grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || { print -u2 "The app is not Developer ID signed with the hardened runtime."; exit 1; }
VERSION=$(version "$APP")

NOTARY_ZIP="$BUILD/$APP_NAME-$VERSION-notarize.zip"
make_zip "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$WCLEANER_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"

ZIP="$DIST/$APP_NAME-$VERSION.zip"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
make_zip "$APP" "$ZIP"
make_dmg "$APP" "$DMG"
/usr/bin/codesign --sign "Developer ID Application" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$WCLEANER_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
checksums "${ZIP:t}" "${DMG:t}"

print "Signed and notarized artifacts (not published):"
print "  $ZIP"
print "  $DMG"
print "Next: follow RELEASING.md to create the GitHub Release and update the Homebrew cask manually."
