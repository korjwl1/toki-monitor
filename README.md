<p align="center">
  <img src="TokiMonitor/Resources/AppIcon_1024.png" alt="Toki Monitor logo" width="160" />
</p>

<h1 align="center">Toki Monitor</h1>

<p align="center">
  <b>macOS menu bar AI token monitor powered by toki's Rust TSDB engine</b><br>
  No proxy. No cloud. Your data stays local.
</p>

<p align="center">
  <sub>The visual companion to <a href="https://github.com/korjwl1/toki"><b>toki</b></a> — the Rust-based token usage tracker.</sub>
</p>

<p align="center">
  <a href="docs/strengths.ko.md">🇰🇷 한국어</a> · <a href="#install">Install</a> · <a href="#features">Features</a> · <a href="#architecture">Architecture</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/swift-5.9%2B-orange" alt="Swift 5.9+">
</p>

---

> **Built on a real TSDB, not a file scanner.** While other menu bar apps poll JSON files every few seconds, Toki Monitor queries toki's fjall time-series database — instant responses at any time range, zero CPU when idle.

---

## Who is this for?

- **Want to see your AI spend at a glance?** A rabbit runs in your menu bar — faster when you're burning tokens. Idle for a few minutes? It falls asleep (zZ). Your spend rate is always visible without opening anything.

- **Need more than "total tokens used"?** Open the Grafana-style dashboard — each panel runs its own PromQL query, with per-panel loading states and query deduplication. Time-series charts, pie charts, stat panels, and more.

- **Using Claude Code AND Codex?** Toki Monitor shows both side-by-side with independent usage bars, rate limit countdowns, and per-provider cost tracking. Switch between aggregated and per-provider views in one click.

- **Worried about runaway costs?** Set a $/min threshold — the icon turns red when you're spending too fast. Or compare against your 24-hour average and get alerted on unusual spikes. Alerts via icon color, system notification, or both.

---

## Why toki's architecture wins

Unlike direct file-polling tools (TokenBar, Tokscale, SessionWatcher), toki uses a **daemon + TSDB** architecture:

| | toki (ours) | Direct polling (competitors) |
|---|---|---|
| **Data collection** | Rust daemon, event-driven — 0% CPU idle | Periodic file scanning — scales with data |
| **Storage** | fjall TSDB (~2.2 MB binary) — indexed | None — lost when app closes |
| **Query** | PromQL instant response (~7 ms) | Full rescan every time |
| **Memory** | ~5 MB idle (Rust, no GC) | 30-50 MB+ (Node.js) |
| **Multi-client** | CLI + menu bar share same daemon | Each tool scans independently |

No proxy required. No TLS interception. No tool reconfiguration. toki reads session files directly — your workflow never changes.

---

## Features

### Always-visible feedback

| Mode | Description |
|------|-------------|
| **Character** | RunCat-style rabbit — sigmoid speed curve reacts to token rate. Sleeps (zZ) when idle. |
| **Numeric** | `1.2K/m` text display with configurable unit (per minute / per second / raw) |
| **Sparkline** | Mini graph of recent token history with configurable time range |

Per-provider or aggregated status bar items. Right-click for quick Settings/Quit.

**Animation speed curve:** Sigmoid-based with midpoint at ~2,000 tok/m. Gentle stroll at low usage, steep acceleration in the 500–3,000 range, sprint at 5,000+. Max rate clamped at 10,000 tok/m for multi-session heavy users.

### Grafana-style dashboard

- **Per-panel query architecture** — each panel executes its own PromQL query with deduplication
- Panel types: time series, bar chart, **pie chart**, stat, gauge, table
- Variable system with provider filter (interpolated into PromQL at query time)
- Time range picker with absolute dates and presets
- Dashboard versioning, annotations, data links
- Project-level token breakdown in pie charts
- Shows in Dock when open, hides when closed

### Usage monitoring

| Provider | Method | Data |
|----------|--------|------|
| **Claude** | OAuth API (`/api/oauth/usage`) | 5-hour & 7-day windows, reset countdown |
| **Codex** | OAuth API (`/backend-api/wham/usage`) | Weekly & 5-hour windows, reset countdown |

No extra login — reads existing CLI credentials (`~/.codex/auth.json`, Keychain). Color-coded usage bars (green → yellow → orange → red). Adaptive polling with faster retry on failure.

### Anomaly detection

- **Velocity alert** — icon color changes when $/min exceeds configurable threshold
- **Historical baseline** — compares current rate against 24-hour average via PromQL
- Alert method: icon color, system notification, or both
- Custom alert colors per alert type
- Off by default — enable in Settings → Notifications

### Settings

- Display mode (aggregated / per-provider) with per-provider style overrides
- Widget order customization (up/down buttons + show/hide)
- Sleep delay (30s / 1m / 1m30s / 2m)
- Claude usage alerts (75%, 90%)
- Full Korean/English localization
- Liquid Glass support (macOS Tahoe)
- About pane with version info and GitHub links

---

## Install

### Homebrew

```bash
brew tap korjwl1/tap
brew install --cask toki-monitor
```

This automatically installs [toki](https://github.com/korjwl1/toki) as a dependency.

### Build from source

```bash
git clone https://github.com/korjwl1/toki-monitor.git
cd toki-monitor
xcodebuild build -scheme TokiMonitor -configuration Release
```

**Requirements:** macOS 14+ (Sonoma), Xcode 15.2+, [toki](https://github.com/korjwl1/toki) CLI installed.

---

## Quick Start

```bash
# 1. Start toki daemon
toki daemon start

# 2. Launch Toki Monitor
open /Applications/TokiMonitor.app

# 3. Use your AI tools as usual
# Claude Code, Codex CLI — token usage appears in real time
```

The menu bar rabbit starts running immediately. Click for provider summary, right-click for settings.

---

## Architecture

```
toki (Rust daemon)              Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS trace, CLI report, OAuth
├─ File watchers (kqueue)       ├─ Domain      // Aggregation, alerts, settings
├─ PromQL engine                └─ Presentation// Menu bar, dashboard, settings
└─ UDS server

Data flow:
  Real-time:  toki daemon → toki trace → UDS → TokiEventStream → TokenAggregator → Menu Bar
  Dashboard:  Panel query → interpolateQuery($__from, $provider) → toki report → PanelDataState → Chart
  Usage:      Claude OAuth / Codex OAuth → UsageMonitor → Usage Widget
```

Toki Monitor is the **presentation layer** for toki. Heavy lifting — parsing, indexing, storage, cost calculation — happens in the Rust daemon. The Swift app focuses on display and interaction.

### Dashboard query system

Each panel defines a PromQL query template (e.g., `usage{since="$__from", $provider}[$__interval] by (model)`). At fetch time:

1. Templates are interpolated with current time range, provider filter, and variables
2. Identical interpolated queries are deduplicated
3. Queries execute in parallel via `withTaskGroup`
4. Results are distributed to panels as `PanelDataState` (idle / loading / loaded / error)
5. `PanelContainerView` handles loading/error states centrally

---

## Supported Providers

| Provider | CLI Tool | Usage API | Status |
|----------|---------|-----------|--------|
| Anthropic | [Claude Code](https://claude.ai/code) | OAuth (`/api/oauth/usage`) | ✅ Supported |
| OpenAI | [Codex CLI](https://github.com/openai/codex) | OAuth (`/backend-api/wham/usage`) | ✅ Supported |
| Google | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | — | ⏳ Planned |

Adding a new provider requires only a toki parser — Toki Monitor picks it up automatically.

---

## Testing

```bash
xcodebuild test -scheme TokiMonitor -destination 'platform=macOS'
```

36 tests across 8 suites: NDJSON parsing, report decoding, state transitions, animation mapping, token formatting, provider registry, data aggregation.

---

## Contributing

Contributions welcome! Please:

1. Fork the repo
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Commit with descriptive messages
4. Open a PR against `main`

For bug reports, please include: macOS version, toki version (`toki --version`), and steps to reproduce.

---

## Competitive Landscape

9+ macOS menu bar apps exist in this space (March 2026). Toki Monitor's unique advantages that **no competitor replicates**:

1. **TSDB-backed history** — query any time range instantly
2. **PromQL query language** — entirely unique among menu bar apps
3. **Grafana-style dashboard** — per-panel queries with deduplication
4. **Animated status icon** — sigmoid speed curve proportional to token rate
5. **Open source + free** — feature depth comparable to $2-5 paid apps

See [competitive analysis](specs/strategy/competitive-analysis-2026-03.md) for details.

---

## Related

- **[toki](https://github.com/korjwl1/toki)** — the Rust TSDB engine that powers Toki Monitor
- **[docs/strengths.md](docs/strengths.md)** — detailed positioning and architecture comparison
- **[docs/strengths.ko.md](docs/strengths.ko.md)** — 한국어 강점 문서

---

## License

[MIT](LICENSE)
