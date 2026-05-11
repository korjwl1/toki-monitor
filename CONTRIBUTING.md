# Contributing to toki-monitor

Reference for anyone sending a patch to toki-monitor. Bug fixes, UI polish, new toki provider parsers, and animation themes are all welcome. Start by opening or commenting on an issue so the design is agreed before code lands.

## Prerequisites

- Xcode 16+
- macOS 14+ (Sonoma or later)
- Swift 6
- [toki](https://github.com/korjwl1/toki) CLI installed locally — Toki Monitor talks to the toki daemon at runtime

## Build and run

```bash
git clone https://github.com/korjwl1/toki-monitor.git
cd toki-monitor
xcodebuild -project TokiMonitor.xcodeproj -scheme TokiMonitor build
```

Open `TokiMonitor.xcodeproj` in Xcode to run interactively (`⌘R`) — the menu bar app launches without a Dock icon.

## Test

```bash
xcodebuild test -scheme TokiMonitor -destination 'platform=macOS'
```

All tests must pass before opening a PR. CI runs the same command.

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
