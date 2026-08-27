# Contributing to toki-monitor

Reference for anyone sending a patch to toki-monitor. Bug fixes, UI polish, new toki provider parsers, and animation themes are all welcome. Start by opening or commenting on an issue so the design is agreed before code lands.

The current branch builds **0.2.4-dev**. It contains unreleased window tracking,
Plan Fit, expanded dashboard, and monitor-settings sync work; do not assume the
Homebrew v0.2.4 cask has those code paths when reproducing a development issue.

## Prerequisites

- Xcode 16+
- macOS 14+ (Sonoma or later)
- Swift 6
- [toki](https://github.com/korjwl1/toki) 2.x CLI installed locally — the app
  launches `toki trace`, runs local `toki query` commands, and talks to its daemon
- The matching unreleased toki source revision for `toki query windows` and the
  `WINDOWS` daemon command when working on Plan Fit or historical window panels
- A matching unreleased toki-sync server when working on monitor-settings sync;
  the currently tagged `toki-sync-protocol` v1.0.0 predates that release pairing

## Build and run

```bash
git clone https://github.com/korjwl1/toki-monitor.git
cd toki-monitor
xcodebuild -project TokiMonitor.xcodeproj -scheme TokiMonitor build
```

GUI apps do not inherit your interactive shell's PATH. If the development toki
binary is outside Homebrew, `~/.cargo/bin`, or `~/.local/bin`, launch with
`TOKI_EXECUTABLE=/absolute/path/to/toki`.

Open `TokiMonitor.xcodeproj` in Xcode to run interactively (`⌘R`) — the menu bar app launches without a Dock icon.

## Test

```bash
xcodebuild test -project TokiMonitor.xcodeproj -scheme TokiMonitor -destination 'platform=macOS'
```

The source currently declares 943 Swift Testing tests and 18 XCTest methods.
Three timer-driven `TokenAggregator` tests are intentionally disabled pending an
injectable production clock; treat any additional skip as a regression. Run the
full command before opening a PR. The repository does not currently contain a
general test workflow, so do not describe a local pass as a CI pass.

## Code style

- Follow existing Swift conventions in the codebase — consistency keeps diffs reviewable.
- Use `async/await`; do not introduce new completion-handler APIs.
- Keep the Clean Architecture split (Data / Domain / Presentation) — features should not leak across layers.

## Pull requests

- One fix or feature per PR. Smaller PRs review faster and revert cleanly.
- Title format: short imperative summary (`Add Gemini provider parser`).
- Body: what changed and *why*. Include screenshots or short clips for UI changes.
- Target `main`. Rebase rather than merge to keep history linear.

## Reporting issues

Bug reports must include:

- macOS version
- `toki --version` output
- Steps to reproduce
- Expected vs. actual behavior

Use the issue templates in the repo.
