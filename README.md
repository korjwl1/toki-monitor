<p align="center">
  <img src="TokiMonitor/Resources/AppIcon_1024.png" alt="Toki Monitor logo" width="128" />
</p>

<h1 align="center">Toki Monitor</h1>

<p align="center">
  <b>A rabbit that runs as fast as you burn tokens.</b><br>
  macOS menu bar monitor for Claude Code and Codex CLI token usage, powered by <a href="https://github.com/korjwl1/toki">toki</a> (<i>tokki</i> = 토끼) — event-driven ingestion, indexed queries, always running in the background.
</p>

```bash
brew tap korjwl1/tap
brew install --cask toki-monitor
```

<p align="center">
  <a href="https://github.com/korjwl1/toki-monitor/releases/latest"><img src="https://img.shields.io/github/v/release/korjwl1/toki-monitor?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/homebrew-toki--monitor-brightgreen" alt="Homebrew">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <img src="https://img.shields.io/badge/swift-6.0%2B-orange" alt="Swift 6.0+">
</p>

<p align="center">
  <a href="README.ko.md">🇰🇷 한국어</a> · <a href="#install">Install</a> · <a href="#features">Features</a> · <a href="#how-it-works">How it works</a> · <a href="#sponsor">Sponsor</a>
</p>

<p align="center">
  <img src="docs/images/rabbit-run.gif" alt="Running rabbit" height="36" />
  &nbsp;&nbsp;&nbsp;
  <img src="docs/images/rabbit-sleep.gif" alt="Sleeping rabbit" height="36" />
</p>

> [!IMPORTANT]
> Version **0.3.0** requires `toki` v2.3.0 or later for Plan Fit and historical
> windows. Monitor-settings sync additionally requires `toki-sync` v2.2.0 or
> later; those releases share `toki-sync-protocol` v1.1.0.

---

## Install

```bash
brew tap korjwl1/tap
brew install --cask toki-monitor
```

This installs the published Toki Monitor v0.3.0 and
[toki](https://github.com/korjwl1/toki) automatically. Launch the app — it starts
and manages the daemon on its own.

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/korjwl1/toki-monitor.git
cd toki-monitor
xcodebuild -project TokiMonitor.xcodeproj -scheme TokiMonitor -configuration Release build
```

Requires macOS 14+ (Sonoma), Xcode 16+, Swift 6, and `toki` v2.3.0 or later.
Set `TOKI_EXECUTABLE=/absolute/path/to/toki` when that binary is not in a
standard Homebrew, Cargo, or `~/.local/bin` location.
</details>

---

## Quick start

```bash
# If you installed via Homebrew, just launch:
open /Applications/TokiMonitor.app

# Use Claude Code / Codex as usual — token usage appears instantly.
# Click the rabbit for details. Right-click for settings.
```

The app auto-starts the toki daemon if it's not running. On first launch, provider settings are synced from toki automatically.

---

## Who is this for?

- See your AI spend at a glance. The rabbit runs while you burn tokens, sleeps (zZ) after a few idle minutes — no window to open, your spend rate is always visible.
- Need more than "total tokens"? Open the **dashboard** for customizable panels, PromQL queries, time-series charts, and pie charts by project. Drill down by model, time range, or provider.
- Using Claude and Codex together? See both side-by-side — usage bars, rate limits, costs. One click to toggle aggregated vs. per-provider.
- Worried about runaway costs? Set a $/min threshold. The icon turns red when you spend too fast, or orange when usage spikes above your 24-hour average.

---

## Features

### Menu bar

| Mode | What you see |
|------|-------------|
| **Character** | Rabbit that runs faster as token rate increases. Sleeps (zZ) when idle. Optional HP bar shows remaining usage. |
| **Numeric** | `1.2K/m` — token rate as text (per minute / per second / raw) |
| **Sparkline** | Mini graph of recent history (configurable: 5m / 10m / 30m / 1h) |

Character mode uses a sigmoid speed curve, steepest in the 500–3,000 tok/m range. Switch modes per provider. Right-click for Settings / Quit.

<p align="center">
  <img src="docs/images/menubar.png" alt="Menu bar modes" width="480" />
</p>

<p align="center">
  <img src="docs/images/sleep-demo.gif" alt="Rabbit sleeping when idle" width="320" />
  <br>
  <sub>The rabbit dozes off (zZ) when you stop using AI for a while.</sub>
</p>

### Dashboard

Each panel runs its own PromQL query. Identical queries are deduplicated automatically.

- Time series, bar chart, pie chart, stat, gauge, table, and state timeline
- Provider filter via PromQL `{provider="..."}` — applied per panel
- Project-level token breakdown with smart path recovery
- Time range picker with presets and absolute dates
- Variables, per-field overrides, value mappings, thresholds, transformations,
  panel repetition, and per-panel time overrides
- Multiple queries per panel, Panel Inspect, and explicit unsupported-query states
- Explore with backend-aware PromQL suggestions
- Dashboard versioning, annotations, JSON import/export, and loss-tolerant schema migration
- Shows in Dock when open, hides when closed

The expanded frame/field/transform pipeline and state timeline were introduced
in v0.3.0.

<p align="center">
  <img src="docs/images/dashboard.png" alt="Dashboard" width="640" />
</p>

### Plan Fit (v0.3.0)

Plan Fit is a curated 28-day view reached from the dashboard sidebar. It uses
finished provider rate-limit windows to produce evidence-backed per-limit
verdicts, weekly/monthly work trends, exhaustion timing, active-use coverage,
model patterns, provider comparisons, and subscription comparisons. It refuses
to recommend a plan when the account shape, coverage, or sample size is not
strong enough. Local and configured server window histories are merged per
provider; a server does not erase richer local history for a provider it lacks.

### Usage monitoring

| Provider | What you get |
|----------|-------------|
| **Claude** | 5-hour, weekly, and available model-scoped windows with reset countdown |
| **Codex** | 5-hour and weekly windows with reset countdown |

Current development builds prefer window state collected by the toki daemon and
fall back to the providers' local credentials when the daemon cannot serve it.
The fallback reads Claude from the macOS Keychain (`Claude Code-credentials`)
and Codex from `~/.codex/auth.json`. Color-coded bars run green → yellow →
orange → red.

Not logged in? The widget shows a prompt instead of hiding — Claude shows "Claude Code login required", Codex shows the `codex --login` command.

### Anomaly detection

- **Velocity alert** — character gets a hit effect (star burst + shake) when $/min exceeds your threshold
- **Historical baseline** — character gets a poison effect (purple bubbles + color pulse) when usage exceeds N× your 24-hour average
- Both effects only appear in character mode
- Off by default. Configure in Settings → Notifications.

<p align="center">
  <img src="docs/images/hit-effect.gif" alt="Hit effect when $/min exceeds threshold" width="320" />
  <br>
  <sub>Star burst + shake effect fires when your spending rate crosses the threshold.</sub>
</p>

### Settings

- Aggregated or per-provider display with independent style overrides
- Widget order (up/down buttons + show/hide per provider)
- HP bar — thin bar above character showing remaining Claude/Codex usage (green → yellow → orange → red)
- Sleep delay (30s / 1m / 1m 30s / 2m)
- Per-window usage alerts for Claude and Codex (75%, 90%)
- About page with toki CLI version and Homebrew update check
- Full Korean / English localization
- Liquid Glass on macOS Tahoe

### Sync (server mode)

Connect to a [toki-sync](https://github.com/korjwl1/toki-sync) server to view usage across all your devices.

- Local / server toggle in the dashboard toolbar — switch between local and server-aggregated data
- Server mode queries toki-sync's PromQL proxy via URLSession (no CLI subprocess overhead)
- Device list with last-seen timestamps for all registered devices
- Token refresh — automatic JWT refresh on 401, system notification when re-login is needed
- HTTPS enforced — non-HTTPS server URLs are rejected (localhost exempt for development)

Configure it in Settings → Sync. The app invokes `toki settings sync enable`,
which opens the browser/device-code login and writes the shared credentials and
sync configuration. Credentials are stored in the macOS Keychain and shared
with the toki daemon.

Version 0.3.0 also contains a second, separately opt-in **Monitor settings
sync** channel. It synchronizes dashboard definitions and monitor
display preferences every 15 minutes and exposes conflicts for an explicit
keep-this-Mac / take-server / keep-both decision. Query results, usage, and cost
figures are not sent through this channel, but dashboard query strings can
contain project or model names. Datasource definitions and launch-at-login stay
local. This channel requires `toki-sync` v2.2.0 or later and its
monitor-settings API.

<p align="center">
  <img src="docs/images/settings-menubar.png" alt="Settings — Menu Bar" width="480" />
  <img src="docs/images/settings-widgets.png" alt="Settings — Widgets" width="480" />
  <img src="docs/images/settings-notifications.png" alt="Settings — Notifications" width="480" />
</p>

---

## How it works

### Why toki?

Every other AI usage monitor works the same way: poll files on a timer, reparse everything, show the result, throw it away. Switch time ranges? Rescan. Close the app? Data gone.

[toki](https://github.com/korjwl1/toki) is different — a Rust daemon that watches AI tool session files via kqueue, event-driven instead of periodically rescanning the whole history. Tokens flow into an embedded time-series database (fjall TSDB), where the indexed history is available to PromQL queries. Toki Monitor still uses low-frequency timers for rate decay, rate-limit state, sync status, and update checks, so “zero CPU” is not a literal whole-app guarantee.

See [docs/strengths.md](docs/strengths.md) for the full comparison against polling- and proxy-based monitors.

| | toki | Every other tool |
|---|---|---|
| **How it collects** | kqueue file watcher — event-driven incremental ingest | Timer-based rescan (30s–5min intervals) |
| **Where it stores** | Embedded TSDB — persistent, indexed | Nowhere — lost when app closes |
| **How it queries** | Indexed PromQL engine | Full file rescan each time |
| **Architecture** | One daemon serves CLI + menu bar + dashboard | Each app rescans independently |

### Architecture

```text
toki (Rust daemon)              Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS, CLI, Keychain, ServerQueryClient
├─ kqueue file watchers         ├─ Domain      // Aggregation, alerts, SyncManager
├─ PromQL engine                └─ Presentation// Menu bar, dashboard, Plan Fit, settings
├─ UDS server
└─ sync thread → toki-sync     toki-sync server (optional)
                                ├─ PromQL/window query API
                                └─ monitor-settings API (toki-sync v2.2+)

Live:   toki trace → monitor-owned UDS → menu bar
Local:  Panel query → toki CLI → daemon/TSDB → frames → panel
Server: Panel query → URLSession → toki-sync → frames → panel
```

### Privacy

- Local mode has no telemetry and keeps usage data on your machine
- Usage APIs read only rate limit status, never prompts or responses
- toki reads session files read-only — never modifies your AI tool data
- Enabling toki-sync uploads usage data to the server you configure
- Enabling monitor-settings sync separately uploads dashboard definitions and
  selected display preferences; its opt-in screen discloses the exact scope

---

## Supported providers

| Provider | CLI tool | Usage API | Status |
|----------|---------|-----------|--------|
| Anthropic | [Claude Code](https://claude.ai/code) | OAuth | Shipped |
| OpenAI | [Codex CLI](https://github.com/openai/codex) | OAuth | Shipped |
| Google | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | — | Planned |

The generic query/dashboard path follows toki's provider-tagged schema. A new
provider still needs metadata in `ProviderRegistry`, and provider-specific
rate-limit widgets need an auth/usage adapter when their APIs differ.

---

## Testing

```bash
xcodebuild test -project TokiMonitor.xcodeproj -scheme TokiMonitor -destination 'platform=macOS'
```

The current source declares **943 Swift Testing tests and 18 XCTest methods**
across IPC/CLI boundaries, dashboard persistence and migration, frame and query
semantics, window and Plan Fit statistics, settings sync conflict handling,
accessibility, contrast, and rendered snapshot checks. Three timer-driven
`TokenAggregator` tests are intentionally disabled because their production
clock is not injectable; they are known skips, not passing coverage.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build commands, and PR guidelines.

Quick path:

1. Fork → feature branch → PR against `main`
2. For bugs: include macOS version, `toki --version`, steps to reproduce

---

## Custom animations

Source contributors can add a bundled character to the menu bar. Each theme is
a folder under `TokiMonitor/Resources/Animations/`:

```text
Resources/Animations/
  rabbit/              ← built-in default
    theme.json
    run_00.png
    run_01.png
    ...
  your-character/      ← add your own
    theme.json
    run_00.png ~ run_XX.png
    sleep_00.png ~ sleep_XX.png   (optional)
```

### Frame specs

- **Size**: 28×18 px (or any size — set in `theme.json`)
- **Format**: transparent background PNG, black only (`#000000`)
- **Template**: frames are rendered as macOS template images (system tints automatically)
- **Naming**: `run_00.png`, `run_01.png`, ... (sequential, zero-padded)
- **Count**: any number of frames — detected automatically

### theme.json

```json
{
  "id": "your-character",
  "name": "Display Name",
  "nameKo": "한국어 이름",
  "frameSize": [28, 18],
  "canvasSize": [28, 18],
  "hpBar": {
    "widthRatio": 0.7,
    "height": 2,
    "yOffset": 1,
    "xOffset": 0
  },
  "sleep": {
    "mode": "overlay",
    "textOffset": [-7, -1],
    "fontSize": 5,
    "interval": 0.8
  }
}
```

| Field | Description |
|-------|-------------|
| `frameSize` | Character draw size in pt (width, height) |
| `canvasSize` | Total canvas size including margins |
| `hpBar.widthRatio` | Bar width as ratio of character width (0.0–1.0) |
| `hpBar.height` | Bar height in pt |
| `hpBar.yOffset` | Distance from top in pt |
| `hpBar.xOffset` | Horizontal offset from center in pt |
| `sleep.mode` | `"overlay"` = auto-generate zZ text, `"frames"` = use `sleep_XX.png` files |
| `sleep.textOffset` | zZ position offset from top-right of character (overlay mode) |
| `sleep.interval` | Seconds per frame during sleep animation |

Themes bundled into the app are discovered at launch. Select one in Settings →
Menu Bar → Character. There is not currently a user-level themes directory.

---

## Upcoming

- Gemini CLI support — Google Gemini provider integration
- Usage reports — weekly/monthly summaries with week-over-week and month-over-month comparisons

---

## Sponsor

<a href="https://github.com/sponsors/korjwl1">
  <img src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?style=for-the-badge&logo=github" alt="Sponsor" />
</a>

If Toki Monitor is useful to you, consider sponsoring to support development.

For commercial use in paid products, please sponsor or [reach out](mailto:korjwl1@gmail.com).

---

## License

[MIT](LICENSE) — built by [@korjwl1](https://github.com/korjwl1)

Part of the [toki](https://github.com/korjwl1/toki) ecosystem.
