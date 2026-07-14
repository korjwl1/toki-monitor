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

## Step 6 — Confirm the Homebrew cask bump

Publishing the release (Step 5) triggers the `.github/workflows/bump-tap.yml`
workflow, which computes the zip's SHA-256, updates `version` + `sha256` in the
tap cask, and opens a PR against `korjwl1/homebrew-tap`. **Do not** edit the
local tap file or push to tap `main` directly — that hand-editing was the source
of version drift this workflow exists to eliminate.

1. Wait for the workflow to open the PR (a few minutes after publish):
   ```bash
   gh run list --repo korjwl1/toki-monitor --workflow bump-tap.yml --limit 1
   gh pr list --repo korjwl1/homebrew-tap --search "toki-monitor <VERSION>"
   ```
2. Review the PR (correct `version` and `sha256`), then merge it:
   ```bash
   gh pr merge --repo korjwl1/homebrew-tap --squash <PR_NUMBER>
   ```

### Manual fallback (only if the workflow can't run)

The workflow needs a `TAP_REPO_TOKEN` repo secret (PAT with write access to
`korjwl1/homebrew-tap`). Until that secret is registered — or if the run fails —
bump the cask by hand:

```bash
shasum -a 256 "build/Build/Products/Release/TokiMonitor-<VERSION>.zip"

# Work in a CLEAN checkout of the tap, NOT the /opt/homebrew tap copy:
git clone https://github.com/korjwl1/homebrew-tap.git
cd homebrew-tap
git checkout -b bump-toki-monitor-<VERSION>

# Edit the two lines in Casks/toki-monitor.rb:
#   version "<VERSION>"
#   sha256  "<SHA256 from shasum above>"

git add Casks/toki-monitor.rb
git commit -m "bump toki-monitor to <VERSION>"
git push -u origin bump-toki-monitor-<VERSION>

# --head is required: gh must open the PR from the branch you just pushed.
gh pr create --repo korjwl1/homebrew-tap \
  --head bump-toki-monitor-<VERSION> \
  --title "toki-monitor <VERSION>" \
  --body "Manual cask bump for v<VERSION>."
```

## Step 7 — Clean up

```bash
rm -rf build
```

Print a final summary with the version, GitHub release URL, and the tap PR
(URL + merge status).
