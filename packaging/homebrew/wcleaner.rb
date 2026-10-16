# Template for an optional alhamsya/homebrew-tap cask. Not published.
# Fill in `version` and `sha256` from a Developer ID signed, notarized release (see RELEASING.md).
cask "wcleaner" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_WCleaner-#{version}.dmg"

  url "https://github.com/alhamsya/wcleaner/releases/download/v#{version}/WCleaner-#{version}.dmg"
  name "WCleaner"
  desc "Menu bar app that cleans up Git worktrees after their pull requests are merged"
  homepage "https://github.com/alhamsya/wcleaner"

  depends_on macos: ">= :sonoma"

  app "WCleaner.app"

  uninstall quit: "io.github.alhamsya.WCleaner"

  # Removes only WCleaner's own settings and local history. Keychain tokens are removed by
  # disconnecting accounts in WCleaner before uninstalling. Repositories are never touched.
  zap trash: [
    "~/Library/Application Support/WCleaner",
    "~/Library/Preferences/io.github.alhamsya.WCleaner.plist",
  ]
end
