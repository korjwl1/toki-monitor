# Toki Monitor — Strengths & Positioning

**A zero-proxy, real-time menu bar AI token monitor powered by toki's Rust TSDB engine.**

Toki Monitor is the macOS UI layer for [toki](https://github.com/korjwl1/toki) — a Rust-based CLI that collects, indexes, and stores AI token usage data in a local time-series database (fjall). The monitor turns `trace` events into live menu-bar animations and `report` queries into Grafana-style dashboards.

## Why toki's architecture wins

Unlike direct file-polling tools (TokenBar, Tokscale, SessionWatcher), toki uses a **daemon + TSDB** architecture:

| | toki (ours) | Direct polling (competitors) |
|---|---|---|
| **Data collection** | Rust daemon with kqueue/FSEvents — event-driven, 0% CPU when idle | Periodic file scanning — CPU cost scales with data |
| **Storage** | fjall TSDB (~2.2 MB binary) — indexed, queryable | None or in-memory — lost when app closes |
| **Query** | PromQL-style instant response | Full rescan on every query |
| **Memory** | ~few MB (Rust, no GC) | 30-50 MB+ (Node.js runtime) or proportional to data |
| **Long-term data** | O(delta) incremental updates | O(total data) full scan, degrades over time |
| **Multi-client** | CLI + menu bar share the same daemon | Each tool scans independently |

## No proxy required

Unlike proxy-based monitors (BurnRate):
- **No network hop, no TLS interception, no tool reconfiguration.** Keep your existing CLI tools as-is.
- **Schema-accurate data.** Structured token events with model, token breakdown, and cost consistency.

## Product strengths

### Always-visible feedback
- RunCat-style rabbit animation — speed proportional to token rate
- Sleep animation (zZ) when idle, configurable delay
- Three display modes: character animation, numeric rate, sparkline graph
- Per-provider or aggregated status bar items

### Grafana-style dashboard
- Customizable panel layout with drag-and-drop
- Time series, bar chart, stat, gauge, and table panels
- PromQL-powered queries via toki CLI
- Variable system, time range picker with absolute dates
- Dashboard versioning and annotations

### Anomaly detection
- **Velocity alert**: icon color changes when cost/min exceeds threshold
- **Historical baseline**: compares against 24-hour average via PromQL
- Configurable alert method: icon color, system notification, or both
- Custom alert colors

### Claude integration
- OAuth-based usage/rate limit monitoring
- 5-hour and 7-day usage bars with reset countdown
- Usage threshold notifications (75%, 90%)

### Codex integration
- Reads OAuth token from ~/.codex/auth.json (no extra login)
- 5-hour and weekly usage bars with localized countdown
- Auto-detects Codex CLI login availability

### UX polish
- Right-click context menu (Settings, Quit)
- Widget order customization with drag-and-drop + show/hide
- Dashboard opens in Dock, hides when closed
- Auto-reconnect on daemon disconnect (3 retries with backoff)
- Liquid Glass design support (macOS Tahoe)
- Full Korean/English localization

### Developer-friendly
- Open source, free, MIT license
- Homebrew distribution (planned)
- Clean Architecture: Data / Domain / Presentation layers
- async/await throughout, unified design system

## Architecture

```
toki (Rust daemon)              Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS trace, CLI report, OAuth
├─ File watchers (kqueue)       ├─ Domain      // Aggregation, alerts, settings
├─ PromQL engine                └─ Presentation// Menu bar, dashboard, settings
└─ UDS server

Data Flow:
  toki daemon → toki trace → UDS → TokiEventStream → TokenAggregator → Menu Bar
  toki report (PromQL) → TokiReportClient → DashboardViewModel → Charts
```

## Competitive landscape (March 2026)

9+ macOS menu bar apps now exist in this space. Toki Monitor's unique advantages that **no competitor replicates**:

1. **TSDB-backed historical analysis** — query any time range instantly
2. **PromQL query language** — entirely unique in the menu bar app space
3. **Grafana-style customizable dashboard** — the only menu bar app offering this
4. **Animated status icon** with speed proportional to token rate
5. **Open source + free** with feature depth comparable to paid apps ($2-5)

## Best fit users

- Developers who want **instant visual feedback** while coding with AI tools
- Users who need **accurate cost tracking** without installing a proxy
- Anyone who wants **history + dashboards + analysis** locally, not on a web service

**One-line positioning:** A lightweight local menu-bar UX powered by a serious Rust TSDB/PromQL engine — no proxy required.
