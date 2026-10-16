# WCleaner Logo Assets

Source repository: https://github.com/alhamsya/wcleaner

- `assets/branding/WCleaner-logo.png`: Original approved WC + WCleaner logo artwork.
- `assets/branding/WCleaner-app-icon-1024.png`: Square app icon cropped from the original artwork (1024×1024).
- `assets/branding/AppIcon.appiconset/`: macOS AppIcon asset catalog, ready to copy into the Xcode asset catalog used by the project.

The artwork has a dark background; it is not transparent. The AppIcon files are generated variants of the same artwork.

To add these files to your local repo:

```sh
cd ~/Projects/wcleaner
# Copy the contents of this ZIP into the repository root.
git add assets/branding
git commit -m "Add WCleaner logo and macOS app icon assets"
git push origin master
```

If this project uses a different branch or app asset catalog, adjust the branch/path accordingly.
