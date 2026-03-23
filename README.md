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
  <a href="docs/strengths.ko.md">🇰🇷 한국어</a>
</p>

---

> **Built on a real TSDB, not a file scanner.** While other menu bar apps poll JSON files every few seconds, Toki Monitor queries toki's fjall time-series database — instant responses at any time range, zero CPU when idle.

---

## Who is this for?

- **Want to see your AI spend at a glance?** A rabbit runs in your menu bar — faster when you're burning tokens. Idle for 3 minutes? It falls asleep. Your spend rate is always visible without opening anything.

- **Need more than "total tokens used"?** Open the Grafana-style dashboard — customizable panels, PromQL queries, time-series charts, annotations. Drill down by model, time range, or provider.

- **Using Claude Code AND Codex?** Toki Monitor shows both side-by-side with independent usage bars, rate limit countdowns, and per-provider cost tracking. Switch between aggregated and per-provider views in one click.

- **Worried about runaway costs?** Set a $/min threshold — the icon turns red when you're spending too fast. Or compare against your 24-hour average and get alerted on unusual spikes.

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
| **Character** | RunCat-style rabbit — speed proportional to token rate. Sleeps (zZ) when idle. |
| **Numeric** | `1.2K/m` text display |
| **Sparkline** | Mini graph of recent token history |

Per-provider or aggregated. Right-click for quick Settings/Quit.

### Grafana-style dashboard

- Drag-and-drop panel layout (time series, bar chart, stat, gauge, table)
- PromQL-powered queries via toki CLI
- Variable system, time range picker, annotations
- Dashboard versioning
- Shows in Dock when open, hides when closed

### Usage monitoring

| Provider | Method | Data |
|----------|--------|------|
| **Claude** | OAuth API (`/api/oauth/usage`) | 5-hour & 7-day windows, reset countdown |
| **Codex** | OAuth API (`/backend-api/wham/usage`) | Weekly & 5-hour windows, reset countdown |

No extra login — reads existing CLI credentials. Color-coded bars (green → yellow → orange → red).

### Anomaly detection

- **Velocity alert** — icon color changes when $/min exceeds threshold
- **Historical baseline** — compares against 24-hour average via PromQL
- Alert method: icon color, system notification, or both
- Custom alert colors, configurable thresholds

### Settings

- Display mode (aggregated / per-provider) with per-provider style overrides
- Widget order customization (drag-and-drop + show/hide)
- Sleep delay (30s / 1m / 1m30s / 2m)
- Claude usage alerts (75%, 90%)
- Full Korean/English localization
- Liquid Glass support (macOS Tahoe)

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

---

## Quick Start

```bash
# 1. Start toki daemon
toki daemon start

# 2. Launch Toki Monitor
open /Applications/TokiMonitor.app
# Or launch from menu bar after installation

# 3. Use your AI tools as usual
# Claude Code, Codex CLI — token usage appears in real time
```

The menu bar icon reacts immediately. Click for provider summary, right-click for settings.

---

## Architecture

```
toki (Rust daemon)              Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS trace, CLI report, OAuth
├─ File watchers (kqueue)       ├─ Domain      // Aggregation, alerts, settings
├─ PromQL engine                └─ Presentation// Menu bar, dashboard, settings
└─ UDS server

Data flow:
  toki daemon → toki trace → UDS → TokiEventStream → TokenAggregator → Menu Bar
  toki report (PromQL) → TokiReportClient → DashboardViewModel → Charts
  Claude OAuth → ClaudeUsageMonitor → Usage Widget
  Codex OAuth → CodexUsageMonitor → Usage Widget
```

Toki Monitor is the **presentation layer** for toki. Heavy lifting — parsing, indexing, storage, cost calculation — happens in the Rust daemon. The Swift app focuses on display and interaction.

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

## Competitive Landscape

9+ macOS menu bar apps exist in this space (March 2026). Toki Monitor's unique advantages that **no competitor replicates**:

1. **TSDB-backed history** — query any time range instantly
2. **PromQL query language** — entirely unique among menu bar apps
3. **Grafana-style dashboard** — the only menu bar app with customizable panels
4. **Animated status icon** — speed proportional to token rate
5. **Open source + free** — feature depth comparable to $2-5 paid apps

See [competitive analysis](specs/strategy/competitive-analysis-2026-03.md) for details.

---

## Related

- **[toki](https://github.com/korjwl1/toki)** — the Rust TSDB engine that powers Toki Monitor
- **[docs/strengths.md](docs/strengths.md)** — detailed positioning and architecture comparison

---

## License

[MIT](LICENSE)
