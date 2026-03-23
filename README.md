<p align="center">
  <img src="TokiMonitor/Resources/AppIcon_1024.png" alt="Toki Monitor logo" width="128" />
</p>

<h1 align="center">Toki Monitor</h1>

<p align="center">
  <b>A rabbit runs in your menu bar — faster when you're burning tokens.</b><br>
  macOS menu bar AI token monitor. No proxy. No cloud. Your data stays local.
</p>

<p align="center">
  <a href="https://github.com/korjwl1/toki-monitor/releases/latest"><img src="https://img.shields.io/github/v/release/korjwl1/toki-monitor?label=release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/homebrew-toki--monitor-brightgreen" alt="Homebrew">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-FSL--1.1--Apache--2.0-green" alt="FSL-1.1-Apache-2.0">
  <img src="https://img.shields.io/badge/swift-5.9%2B-orange" alt="Swift 5.9+">
</p>

<p align="center">
  <a href="README.ko.md">🇰🇷 한국어</a> · <a href="#install">Install</a> · <a href="#features">Features</a> · <a href="#how-it-works">How it works</a> · <a href="#sponsor">Sponsor</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" alt="Toki Monitor demo — rabbit animation and dashboard" width="640" />
</p>

---

> **toki** = **to**ken **i**nspector — sounds like *tokki* (토끼, rabbit in Korean). Toki Monitor is the macOS visual companion to [toki](https://github.com/korjwl1/toki), a Rust daemon that indexes your AI tool session files into a local time-series database ([fjall](https://github.com/fjall-rs/fjall)). The monitor stays lightweight because heavy parsing, indexing, and cost calculation live in the daemon.

---

## Install

```bash
brew tap korjwl1/tap
brew install --cask toki-monitor
```

This installs [toki](https://github.com/korjwl1/toki) automatically. Launch the app — the daemon starts on its own.

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/korjwl1/toki-monitor.git
cd toki-monitor
xcodebuild build -scheme TokiMonitor -configuration Release
```

Requires macOS 14+ (Sonoma), Xcode 15.2+, and [toki](https://github.com/korjwl1/toki) CLI.
</details>

---

## Quick Start

```bash
# If you installed via Homebrew, just launch:
open /Applications/TokiMonitor.app

# Use Claude Code / Codex as usual — token usage appears instantly.
# Click the rabbit for details. Right-click for settings.
```

The app auto-starts the toki daemon if it's not running. On first launch, provider settings are synced from toki automatically.

---

## Who is this for?

- **Want to see your AI spend at a glance?** The rabbit runs when you're using tokens. Idle for a few minutes? It falls asleep (zZ). No need to open anything — your spend rate is always visible.

- **Need more than "total tokens"?** Open the dashboard — customizable panels, PromQL queries, time-series charts, pie charts by project. Drill down by model, time range, or provider.

- **Using Claude AND Codex?** See both side-by-side — usage bars, rate limits, costs. One click to toggle aggregated vs. per-provider.

- **Worried about runaway costs?** Set a $/min threshold. The icon turns red when you're spending too fast, or orange when usage spikes above your 24-hour average.

---

## Features

### Menu bar

| Mode | What you see |
|------|-------------|
| **Character** | Rabbit that runs faster as token rate increases. Sigmoid speed curve — steep in the 500–3,000 tok/m range. Sleeps (zZ) when idle. |
| **Numeric** | `1.2K/m` — token rate as text (per minute / per second / raw) |
| **Sparkline** | Mini graph of recent history (configurable: 5m / 10m / 30m / 1h) |

Switch modes per provider. Right-click for Settings / Quit.

<p align="center">
  <img src="docs/images/menubar.png" alt="Menu bar modes" width="480" />
</p>

### Dashboard

Each panel runs its own PromQL query. Identical queries are deduplicated automatically.

- Time series, bar chart, **pie chart**, stat, gauge, table
- Provider filter via PromQL `{provider="..."}` — applied per panel
- Project-level token breakdown with smart path recovery
- Time range picker with presets and absolute dates
- Dashboard versioning and annotations
- Shows in Dock when open, hides when closed

<p align="center">
  <img src="docs/images/dashboard.png" alt="Dashboard" width="640" />
</p>

### Usage monitoring

| Provider | What you get |
|----------|-------------|
| **Claude** | 5-hour and 7-day windows with reset countdown |
| **Codex** | Weekly and 5-hour windows with reset countdown |

Reads existing CLI credentials — no extra login. Color-coded bars: green → yellow → orange → red.

Not logged in? The widget shows a login prompt instead of hiding — Claude links to Settings, Codex shows the `codex --login` command.

### Anomaly detection

- **Velocity alert** — icon color changes when $/min exceeds your threshold
- **Historical baseline** — compares against your 24-hour average via PromQL
- Choose: icon color change, system notification, or both
- Custom alert colors per type
- Off by default. Configure in Settings → Notifications.

### Settings

- Aggregated or per-provider display with independent style overrides
- Widget order (up/down buttons + show/hide per provider)
- Sleep delay (30s / 1m / 1m 30s / 2m)
- Usage alerts (Claude 75%, 90%)
- About page with toki CLI version and Homebrew update check
- Full Korean / English localization
- Liquid Glass on macOS Tahoe

---

## How it works (and why it's fast)

Other menu bar apps rescan files on every poll. Toki queries an indexed database — instant at any range, zero CPU at idle.

| | toki | File-polling tools |
|---|---|---|
| **Collection** | Rust daemon, event-driven — 0% CPU idle | Periodic scan, scales with data |
| **Storage** | fjall TSDB, indexed | None — lost when app closes |
| **Query** | ~7 ms (PromQL) | Full rescan each time |
| **Memory** | ~5 MB idle | 30–50 MB+ |
| **Clients** | CLI + menu bar share one daemon | Each tool scans on its own |

```
toki (Rust)                     Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS, CLI, OAuth
├─ kqueue file watchers         ├─ Domain      // Aggregation, alerts
├─ PromQL engine                └─ Presentation// Menu bar, dashboard
└─ UDS server

Real-time:  daemon → trace → UDS → EventStream → Aggregator → Menu Bar
Dashboard:  Panel query → interpolate($__from, $provider) → toki report → PanelDataState → Chart
Usage:      Claude OAuth / Codex OAuth → Monitor → Widget
```

### Privacy

- All data stays on your machine — no telemetry, no cloud
- Usage APIs read only rate limit status, never prompts or responses
- toki reads session files read-only — never modifies your AI tool data

---

## Supported Providers

| Provider | CLI Tool | Usage API | Status |
|----------|---------|-----------|--------|
| Anthropic | [Claude Code](https://claude.ai/code) | OAuth | ✅ |
| OpenAI | [Codex CLI](https://github.com/openai/codex) | OAuth | ✅ |
| Google | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | — | ⏳ Planned |

Adding a provider only requires a toki parser — Toki Monitor picks it up automatically.

---

## Testing

```bash
xcodebuild test -scheme TokiMonitor -destination 'platform=macOS'
```

36 tests, 8 suites: event parsing, report decoding, state transitions, animation mapping, formatting, provider registry, data aggregation.

---

## Contributing

Contributions welcome!

1. Fork → feature branch → PR against `main`
2. For bugs: include macOS version, `toki --version`, steps to reproduce

---

## Upcoming

- **Gemini CLI support** — Google Gemini provider integration
- **Custom animations** — bring your own character frames
- **Multi-device sync** — share usage data across machines via toki-sync
- **Usage reports** — weekly/monthly summaries with week-over-week and month-over-month comparisons

---

## Sponsor

<a href="https://github.com/sponsors/korjwl1">
  <img src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?style=for-the-badge&logo=github" alt="Sponsor" />
</a>

If Toki Monitor is useful to you, consider sponsoring to support development.

For commercial use in paid products, please sponsor or [reach out](mailto:korjwl1@gmail.com).

---

## License

[FSL-1.1-Apache-2.0](LICENSE) — built by [@korjwl1](https://github.com/korjwl1)

Part of the [toki](https://github.com/korjwl1/toki) ecosystem.
