# Contributing to toki-monitor

Reference for anyone sending a patch to toki-monitor. Bug fixes, UI polish, new toki provider parsers, and animation themes are all welcome. Start by opening or commenting on an issue so the design is agreed before code lands.

The current branch builds **0.3.0**. Window tracking, Plan Fit, the expanded
dashboard, and monitor-settings sync are release features in this version.

## Prerequisites

- Xcode 16+
- macOS 14+ (Sonoma or later)
- Swift 6
- [toki](https://github.com/korjwl1/toki) v2.3.0 or later installed locally — the app
  launches `toki trace`, runs local `toki query` commands, and talks to its daemon
- `toki-sync` v2.2.0 or later when working on monitor-settings sync

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
