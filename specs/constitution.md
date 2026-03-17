<!--
Sync Impact Report
- Version change: N/A → 1.0.0 (initial creation)
- Added sections:
  - Core Principles (8 principles tailored to macOS menu bar app + toki integration)
  - Development Workflow (SDD-aligned)
  - Quality Gates
  - Decision-Making Framework
- Templates requiring updates:
  - .spec-mix/active-mission/templates/plan-template.md — ✅ no update needed (Constitution Check section is generic)
  - .spec-mix/active-mission/templates/spec-template.md — ✅ no update needed (structure is generic)
  - .spec-mix/active-mission/templates/tasks-template.md — ✅ no update needed (vertical slice approach aligns)
- Follow-up TODOs: none
-->

# Project Constitution: Toki Monitor

## Core Principles

### 1. Native macOS Experience

- The app MUST be a first-class macOS citizen: menu bar item (NSStatusItem),
  native popover, and optional dashboard window
- All UI MUST use SwiftUI with AppKit integration where required
  (NSStatusBarButton, NSPopover)
- Animations in the menu bar MUST be lightweight and non-distracting,
  adapting intensity to token throughput rate
- The app MUST respect system appearance (Dark/Light mode) and
  accessibility settings (Reduce Motion, VoiceOver)

**Rationale**: Users expect menu bar utilities to feel invisible until needed.
A non-native or resource-heavy menu bar app erodes trust quickly.

### 2. Minimal Resource Footprint

- Idle CPU usage MUST remain below 1% (no polling; use event-driven updates)
- Memory footprint MUST stay under 50 MB during normal operation
- The app MUST NOT drain battery — prefer FSEvents and Unix Domain Socket
  listeners over periodic timers
- Animation frame updates MUST be throttled when the popover is not visible

**Rationale**: Menu bar apps run 24/7. Users will remove any utility that
visibly impacts system performance or battery life.

### 3. toki (clitrace) Integration First

- All token data MUST flow through the toki library's public API
  (`start`, `Handle`, `Database`, `Sink` trait)
- Real-time events MUST be consumed via the UDS sink
  (`uds://~/.config/toki/daemon.sock` or equivalent)
- Historical reports MUST use toki's TSDB query engine
  (daily/weekly/monthly/hourly/query subcommands)
- The app MUST NOT duplicate toki's data storage — query toki's fjall DB
  directly or via its CLI/library interface
- Provider support (Claude, Gemini, etc.) MUST be driven by toki's
  `LogParser` trait implementations, not hardcoded in the UI layer

**Rationale**: toki already solves token tracking, storage, and reporting.
Duplicating this logic creates drift and maintenance burden. The monitor
app is a presentation layer over toki's data.

### 4. Provider-Agnostic Architecture

- The UI layer MUST display provider data generically using a common
  `TokenUsageModel` protocol, not provider-specific views
- Adding a new AI provider MUST NOT require changes to the menu bar,
  popover, or dashboard UI code
- Provider metadata (name, icon, color) MUST be data-driven
  (configuration or toki-provided) rather than hardcoded
- Cost display MUST gracefully degrade when pricing data is unavailable
  for a provider (show token counts only)

**Rationale**: The AI tool landscape changes rapidly. The app must
accommodate new providers (Gemini, GPT, etc.) without UI refactoring.

### 5. Clear Layered Structure

- **Data Layer**: toki integration (UDS client, CLI wrapper, DB reader)
- **Domain Layer**: Token usage models, aggregation logic, animation state
- **Presentation Layer**: SwiftUI views (menu bar, popover, dashboard)
- Dependencies MUST point inward: Presentation → Domain → Data
- The Data layer MUST NOT import SwiftUI; the Domain layer MUST NOT
  import AppKit
- Each layer MUST be independently testable

**Rationale**: A menu bar app with a dashboard has enough surface area to
benefit from separation. Clean layers also enable future targets
(widget, CLI, iOS companion) without rewriting business logic.

### 6. Testing at Boundaries

- Integration tests MUST verify toki UDS communication (connect, parse
  NDJSON events, handle disconnection)
- UI tests MUST cover popover display, provider list rendering, and
  dashboard navigation
- Unit tests MUST cover token aggregation, animation state mapping,
  and cost calculation logic
- Mocks are permitted ONLY for the toki IPC boundary, not for internal
  domain logic
- Aim for >80% coverage on Domain and Data layers

**Rationale**: The highest-risk boundaries are toki IPC and the
real-time event stream. Testing these prevents silent data loss.

### 7. Progressive Disclosure

- Menu bar icon MUST convey token activity at a glance (animation speed
  or intensity reflects throughput)
- Popover MUST show per-provider summary for the recent time window
  (e.g., last hour) without requiring clicks
- Dashboard MUST provide drill-down into historical data with
  configurable time ranges, per-session breakdowns, and cost analysis
- Settings MUST be accessible from the popover, not buried in a
  separate preferences window

**Rationale**: Different information needs require different depths.
The menu bar → popover → dashboard progression mirrors how RunCat
and Stats handle this, which users already understand.

### 8. Graceful Degradation

- If toki daemon is not running, the menu bar MUST show a clear
  "disconnected" state and offer a one-click start option
- If no token events have been received, the app MUST show an empty
  state with guidance, not crash or show stale data
- Network-dependent features (pricing fetch) MUST work offline by
  falling back to toki's cached pricing data
- The app MUST handle toki daemon restarts without requiring an app
  restart

**Rationale**: The toki daemon is an external dependency. The monitor
must remain useful and informative even when that dependency is
temporarily unavailable.

## Development Workflow

1. **Specification**: Define feature scope with user stories and acceptance criteria
2. **Planning**: Create technical implementation plan with Swift/SwiftUI specifics
3. **Implementation**: Build vertical slices (menu bar → popover → dashboard)
4. **Review**: Code review with focus on performance and memory profile
5. **Integration**: Merge to main branch
6. **Distribution**: Build signed .app bundle for local use or notarized distribution

## Quality Gates

Before merging to main:
- [ ] All XCTest suites passing
- [ ] No Xcode warnings or analyzer issues
- [ ] Memory profiled with Instruments (no leaks, footprint within budget)
- [ ] Menu bar animation verified at 0, low, and high token throughput
- [ ] Dark mode and Light mode visually verified
- [ ] toki daemon disconnect/reconnect scenario tested
- [ ] Documentation updated for any new user-facing feature

## Decision-Making Framework

When faced with technical choices:

1. Does it preserve the native macOS feel?
2. Does it stay within the resource budget (CPU <1%, memory <50MB)?
3. Does it leverage toki rather than reimplementing?
4. Can a new provider be added without touching this code?
5. Document the decision and rationale

---

**Governance**

- **Ratification Date**: 2026-03-17
- **Version**: 1.0.0
- **Amendment Procedure**: Any principle change requires updating this
  document with a version bump (MAJOR for removals/redefinitions,
  MINOR for additions, PATCH for clarifications) and verifying
  consistency with plan, spec, and task templates.
