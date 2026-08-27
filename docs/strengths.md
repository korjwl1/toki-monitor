# Toki Monitor — strengths and positioning

**A zero-proxy, real-time menu bar AI token monitor powered by toki's Rust TSDB engine.**

Toki Monitor is the macOS UI layer for [toki](https://github.com/korjwl1/toki) — a Rust-based CLI that collects, indexes, and stores AI token usage data in a local time-series database (fjall). The monitor turns `trace` events into live menu-bar animations and `report` queries into Grafana-style dashboards.

> **Development status:** this document describes the **0.2.4-dev** source
> checkout. Plan Fit, historical window panels, the expanded dashboard data
> model, and monitor-settings sync are not part of the published v0.2.4 cask and
> require matching unreleased toki/toki-sync revisions.

## Why toki's architecture wins

Unlike direct file-polling tools (TokenBar, Tokscale, SessionWatcher), toki uses a **daemon + TSDB** architecture:

| | toki (ours) | Direct polling (competitors) |
|---|---|---|
| **Data collection** | Rust daemon with kqueue — event-driven incremental ingest | Periodic file scanning — CPU cost scales with data |
| **Storage** | fjall TSDB (~2.2 MB binary) — indexed, queryable | None or in-memory — lost when app closes |
| **Query** | Indexed PromQL-style query engine | Full rescan on every query |
| **Long-term data** | O(delta) incremental updates | O(total data) full scan, degrades over time |
| **Multi-client** | CLI + menu bar share the same daemon | Each tool scans independently |

## No proxy required

Unlike proxy-based monitors (BurnRate):

- No network hop, no TLS interception, no tool reconfiguration. Keep your existing CLI tools as-is.
- Schema-accurate data. Structured token events with model, token breakdown, and cost consistency.

## Product strengths

### Always-visible feedback

- RunCat-style rabbit animation — speed proportional to token rate
- Sleep animation (zZ) when idle, configurable delay
- Three display modes: character animation, numeric rate, sparkline graph
- Per-provider or aggregated status bar items

### Grafana-style dashboard

- Customizable panel layout with drag-and-drop
- Time series, bar chart, pie, stat, gauge, table, and state-timeline panels
- Local toki CLI and optional toki-sync datasources, selectable per dashboard or query
- Multi-query frames, transformations, value mappings, thresholds, field overrides,
  panel repeat, panel time overrides, and inspectable query states
- Backend-aware Explore, variables, time range picker, import/export, versioning,
  annotations, and loss-tolerant schema migration

### Plan Fit (0.2.4-dev)

- Curated 28-day analysis over provider rate-limit windows
- Per-limit verdicts that withhold recommendations when evidence is too thin
- Weekly/monthly trends, active-use coverage, exhaustion timing, model patterns,
  provider comparisons, and subscription comparisons
- Per-provider arbitration between local and multi-device server history

### Anomaly detection

- **Velocity alert**: icon color changes when cost/min exceeds threshold
- **Historical baseline**: compares against 24-hour average via PromQL
- Per-provider overrides and configurable thresholds
- Separate system notifications when provider windows cross enabled 75%/90% levels

### Claude integration

- OAuth-based usage/rate limit monitoring
- 5-hour and 7-day usage bars with reset countdown
- Usage threshold notifications (75%, 90%)

### Codex integration

- Reads OAuth token from `~/.codex/auth.json` (no extra login)
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

- Open source and free under the MIT License
- Available via Homebrew tap: `brew tap korjwl1/tap && brew install --cask toki-monitor`
- Clean Architecture: Data / Domain / Presentation layers
- async/await throughout, unified design system

## Architecture

```text
toki (Rust daemon)              Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS trace, CLI, Keychain, sync HTTP
├─ File watchers (kqueue)       ├─ Domain      // frames, windows, Plan Fit, settings
├─ PromQL engine                └─ Presentation// Menu bar, dashboard, Plan Fit, settings
├─ UDS server
└─ sync thread → toki-sync     toki-sync (optional)

Data Flow:
  toki trace → monitor-owned UDS → TokiEventStream → TokenAggregator → Menu Bar
  local:  toki query → TokiReportClient → frames → Dashboard / Plan Fit
  server: URLSession → toki-sync → frames/windows → Dashboard / Plan Fit
```

Usage sync and monitor-settings sync are separate opt-ins. The latter uploads
dashboard definitions and selected display preferences, not query results or
usage/cost figures, and presents divergent edits for an explicit decision.

## Competitive landscape

Toki Monitor's architectural differentiators are:

1. **TSDB-backed historical analysis** — query any time range instantly
2. **PromQL query language** with explicit local/server datasource behavior
3. **Grafana-style customizable dashboard** plus a curated Plan Fit view
4. **Animated status icon** with speed proportional to token rate
5. **Open source + free** with feature depth comparable to paid apps ($2-5)

## Best fit users

- Developers who want **instant visual feedback** while coding with AI tools
- Users who need **accurate cost tracking** without installing a proxy
- Anyone who wants **history + dashboards + analysis** locally, not on a web service

**One-line positioning:** A lightweight local menu-bar UX powered by a serious Rust TSDB/PromQL engine — no proxy required.
