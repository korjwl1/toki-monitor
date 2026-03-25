---
name: bump-version
description: Bump version, build, create GitHub release, and update Homebrew cask
disable-model-invocation: true
---

Bump the version to `$ARGUMENTS`, build the app, create a GitHub release, and update the Homebrew cask.

If no argument is provided, ask the user what version to bump to.

## Step 1 — Update version strings

Update the version in **both** files to the exact same value:

1. **`TokiMonitor/Info.plist`** — the `<string>` under `CFBundleShortVersionString`
2. **`project.yml`** — the `CFBundleShortVersionString` value

Rules:
- Semver format only (e.g. `0.2.0`, `1.0.0`). No `v` prefix.
- Show a summary of what was changed.

## Step 2 — Commit and tag

1. Stage the two changed files and create a commit: `chore: bump version to <VERSION>`
2. Create a git tag: `v<VERSION>`
3. Push the commit and tag to origin.

## Step 3 — Build the app

```bash
xcodebuild -project TokiMonitor.xcodeproj -scheme TokiMonitor -configuration Release -derivedDataPath build clean build
```

If the build fails, stop and report the error. Do NOT continue.

## Step 4 — Package the zip

```bash
# Find the .app in the build output
cd build/Build/Products/Release
# Create the release zip
zip -r -y "TokiMonitor-<VERSION>.zip" TokiMonitor.app
```

## Step 5 — Create GitHub release

```bash
gh release create "v<VERSION>" \
  "build/Build/Products/Release/TokiMonitor-<VERSION>.zip" \
  --repo korjwl1/toki-monitor \
  --title "v<VERSION>" \
  --generate-notes
```

## Step 6 — Update Homebrew cask

1. Compute the SHA-256 of the zip:
   ```bash
   shasum -a 256 "build/Build/Products/Release/TokiMonitor-<VERSION>.zip"
   ```
2. Edit the cask file at the **local tap path**:
   `/opt/homebrew/Library/Taps/korjwl1/homebrew-tap/Casks/toki-monitor.rb`
   - Update `version` to the new version string (no `v` prefix).
   - Update `sha256` to the new hash.
3. Commit and push in the tap repo:
   ```bash
   cd /opt/homebrew/Library/Taps/korjwl1/homebrew-tap
   git add Casks/toki-monitor.rb
   git commit -m "bump toki-monitor to <VERSION>"
   git push origin main
   ```

## Step 7 — Clean up

```bash
rm -rf build
```

Print a final summary with the version, GitHub release URL, and confirmation that the cask was updated.
