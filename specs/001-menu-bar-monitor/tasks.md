# Tasks: Menu Bar Token Monitor

**Input**: Design documents from `/specs/001-menu-bar-monitor/`
**Prerequisites**: plan.md (required), spec.md (required for user stories)

## Vertical Slice Approach

Each Work Package (WP) is a **complete vertical slice**:
- Contains all layers needed (Data → Domain → Presentation)
- Independently testable and deployable
- Delivers user-visible value
- Can be reviewed and merged separately

```
┌──────────────────────────────────────────────────────────────────┐
│              Feature: Menu Bar Token Monitor                      │
├───────────┬───────────┬───────────┬───────────┬─────────────────┤
│   WP00    │   WP01    │   WP02    │   WP03    │      WP04       │
│  Setup    │  Connect  │  MenuBar  │  Popover  │    Dashboard    │
│           │  + US4    │  + US1    │  + US2    │    + US3        │
├───────────┼───────────┼───────────┼───────────┼─────────────────┤
│  Config   │  Data     │  Domain   │  Domain   │  Data (Report)  │
│  Project  │  Domain   │  Present  │  Present  │  Domain         │
│  Deps     │  Present  │  Tests    │  Tests    │  Present        │
├───────────┼───────────┼───────────┼───────────┼─────────────────┤
│ ✓ Builds  │ ✓ Connects│ ✓ Animates│ ✓ Shows   │ ✓ Shows charts  │
└───────────┴───────────┴───────────┴───────────┴─────────────────┘
```

## Task Tracking

- **tasks.md** (this file): Overview with checkbox format
- **Work Package files**: `tasks/{planned,doing,for_review,done}/WPxx.y.md`

---

## Phase 0: Project Setup

> **Purpose**: Xcode 프로젝트 생성, 빌드 가능한 빈 앱 셸
> **Goal**: `Cmd+R`로 빌드 & 실행 → 메뉴바에 정적 아이콘 표시

### WP00: Project Bootstrap (Foundation)

**Vertical Scope**: Xcode 프로젝트 + 메뉴바 빈 아이콘

| Layer | Deliverable |
|-------|-------------|
| Config | Xcode project, Info.plist (LSUIElement), macOS 14+ target |
| Structure | Data/ Domain/ Presentation/ 3레이어 폴더 |
| Presentation | NSStatusItem + 정적 아이콘 |
| Verification | 빌드 성공, 메뉴바에 아이콘 표시 |

**Tasks**:
- [ ] T001 Create Xcode project with SwiftUI App lifecycle in `TokiMonitor/TokiMonitorApp.swift`
- [ ] T002 Configure Info.plist with LSUIElement=YES and macOS 14+ deployment target
- [ ] T003 [P] Create Data/ Domain/ Presentation/ directory structure per plan.md
- [ ] T004 [P] Add placeholder app icon to `TokiMonitor/Resources/Assets.xcassets/`
- [ ] T005 Implement basic StatusBarController with static NSStatusItem in `TokiMonitor/Presentation/MenuBar/StatusBarController.swift`
- [ ] T006 Verify app builds and shows static icon in menu bar

**Checkpoint**: 빌드 성공 + 메뉴바 정적 아이콘 → Ready for vertical slices

---

## Phase 1: toki 연결 + 데몬 관리 (US4 - P1)

> **Purpose**: toki 데몬과 UDS 연결, 연결 상태 관리, 원클릭 시작
> **User Story**: US4 - toki 데몬 연결 관리
> **Independent Test**: toki daemon stop → 앱 상태 변화 → 원클릭 시작 → 재연결

### WP01: toki UDS Connection (US4)

**Vertical Scope**: UDS 연결 + 상태 관리 + 재연결 + 팝오버 연결 상태 표시

| Layer | Deliverable |
|-------|-------------|
| Data | TokiConnection (NWConnection UDS), TokiEvent Codable |
| Domain | ConnectionManager (상태 머신, 재연결), ConnectionState enum |
| Presentation | DisconnectedView (팝오버), 메뉴바 연결 상태 아이콘 |
| Test | UDS 연결/해제/재연결 테스트 |

**Tasks**:
- [ ] T007 [US4] Create TokiEvent Codable model in `TokiMonitor/Data/Models/TokiEvent.swift`
- [ ] T008 [US4] Create TokiReportRequest and TokiReportResponse Codable models in `TokiMonitor/Data/Models/`
- [ ] T009 [US4] Implement TokiConnection UDS client with NWConnection in `TokiMonitor/Data/TokiConnection.swift`
- [ ] T010 [US4] Implement NDJSON line parser in TokiEventStream in `TokiMonitor/Data/TokiEventStream.swift`
- [ ] T011 [US4] Create ConnectionState enum and ConnectionManager with reconnect logic in `TokiMonitor/Domain/ConnectionManager.swift`
- [ ] T012 [US4] Implement "toki daemon start" Process launch in ConnectionManager
- [ ] T013 [US4] Create DisconnectedView with "toki 시작" button in `TokiMonitor/Presentation/Popover/DisconnectedView.swift`
- [ ] T014 [US4] Update StatusBarController to show connected/disconnected icon state in `TokiMonitor/Presentation/MenuBar/StatusBarController.swift`
- [ ] T015 [US4] Wire TokiConnection → ConnectionManager → StatusBarController in TokiMonitorApp
- [ ] T016 [US4] Write ConnectionManager reconnect tests in `TokiMonitor/Tests/TokiMonitorTests/Domain/ConnectionManagerTests.swift`
- [ ] T017 [US4] Write TokiEventStream NDJSON parsing tests in `TokiMonitor/Tests/TokiMonitorTests/Data/TokiEventStreamTests.swift`

**Acceptance Criteria**:
- [ ] toki 데몬 실행 시 connected 아이콘 표시
- [ ] toki 데몬 미실행 시 disconnected 아이콘 + DisconnectedView
- [ ] "toki 시작" 클릭 → 데몬 시작 → 자동 재연결
- [ ] 데몬 크래시 → 3회 재연결 시도 (5초 간격) → 실패 시 disconnected

**Deploy Check**: ✓ Yes — 연결 상태만으로 독립 가치

---

## Phase 2: 실시간 메뉴바 애니메이션 (US1 - P1)

> **Purpose**: 토큰 이벤트 → 애니메이션 속도 매핑, 3종 스타일 지원
> **User Story**: US1 - 실시간 메뉴바 토큰 애니메이션
> **Independent Test**: Claude Code 사용 시 메뉴바 애니메이션 속도 변화 확인

### WP02: Menu Bar Animation (US1)

**Vertical Scope**: 이벤트 수신 → 처리량 계산 → 애니메이션 3종

| Layer | Deliverable |
|-------|-------------|
| Domain | AnimationState, AnimationStyle, AnimationStateMapper, TokenAggregator (rate calc) |
| Presentation | CharacterAnimationView, NumericBadgeView, SparklineView |
| Settings | AnimationStyle 선택 |
| Test | AnimationStateMapper 유닛 테스트 |

**Tasks**:
- [ ] T018 [US1] Create AnimationState and AnimationStyle enums in `TokiMonitor/Domain/AnimationStateMapper.swift`
- [ ] T019 [US1] Implement AnimationStateMapper (token rate → state) in `TokiMonitor/Domain/AnimationStateMapper.swift`
- [ ] T020 [US1] Implement TokenAggregator for real-time rate calculation in `TokiMonitor/Domain/TokenAggregator.swift`
- [ ] T021 [P] [US1] Create CharacterAnimationView with frame-based animation in `TokiMonitor/Presentation/MenuBar/CharacterAnimationView.swift`
- [ ] T022 [P] [US1] Create NumericBadgeView ("1.2K/m" display) in `TokiMonitor/Presentation/MenuBar/NumericBadgeView.swift`
- [ ] T023 [P] [US1] Create SparklineView (mini graph) in `TokiMonitor/Presentation/MenuBar/SparklineView.swift`
- [ ] T024 [US1] Add placeholder character frames (5+ simple shapes) to `TokiMonitor/Resources/Assets.xcassets/`
- [ ] T025 [US1] Update StatusBarController to switch animation styles and update based on AnimationState in `TokiMonitor/Presentation/MenuBar/StatusBarController.swift`
- [ ] T026 [US1] Add Reduce Motion support (force numeric mode) in StatusBarController
- [ ] T027 [US1] Wire TokiEventStream → TokenAggregator → AnimationStateMapper → StatusBarController
- [ ] T028 [US1] Write AnimationStateMapper tests in `TokiMonitor/Tests/TokiMonitorTests/Domain/AnimationStateMapperTests.swift`
- [ ] T029 [US1] Write TokenAggregator rate calculation tests in `TokiMonitor/Tests/TokiMonitorTests/Domain/TokenAggregatorTests.swift`

**Acceptance Criteria**:
- [ ] 토큰 이벤트 수신 → 500ms 이내 애니메이션 반영
- [ ] 30초 이벤트 없음 → idle 상태 전환
- [ ] 3종 스타일 모두 동작 (캐릭터/수치/스파크라인)
- [ ] Reduce Motion 활성화 → 자동 수치 모드

**Deploy Check**: ✓ Yes — 메뉴바 애니메이션만으로 독립 가치

---

## Phase 3: 프로바이더별 사용량 팝오버 (US2 - P1)

> **Purpose**: 팝오버에서 프로바이더별 토큰/비용 요약 + 합산 행
> **User Story**: US2 - 프로바이더별 사용량 팝오버
> **Independent Test**: 메뉴바 클릭 → 팝오버 → 프로바이더별 수치 표시

### WP03: Provider Summary Popover (US2)

**Vertical Scope**: 프로바이더 매핑 → 집계 → 팝오버 UI

| Layer | Deliverable |
|-------|-------------|
| Domain | ProviderRegistry, ProviderSummary, TokenAggregator (provider grouping) |
| Presentation | PopoverContentView, ProviderRowView, TotalSummaryView |
| Settings | TimeRange 선택 (30m/1h/today), 대시보드 버튼 |
| Data | TokiReportClient (UDS report query) |
| Test | ProviderRegistry, TokenAggregator 그룹 테스트 |

**Tasks**:
- [ ] T030 [US2] Create ProviderInfo and ProviderRegistry (model prefix → provider mapping) in `TokiMonitor/Domain/ProviderRegistry.swift`
- [ ] T031 [US2] Create ProviderSummary model in `TokiMonitor/Domain/ProviderSummary.swift`
- [ ] T032 [US2] Create TokenUsageModel protocol in `TokiMonitor/Domain/TokenUsageModel.swift`
- [ ] T033 [US2] Extend TokenAggregator with provider grouping and time range filtering in `TokiMonitor/Domain/TokenAggregator.swift`
- [ ] T034 [US2] Implement TokiReportClient for UDS report queries in `TokiMonitor/Data/TokiReportClient.swift`
- [ ] T035 [US2] Create TimeRange enum and integrate into settings in `TokiMonitor/Domain/TokenAggregator.swift`
- [ ] T036 [P] [US2] Create ProviderRowView (icon, name, tokens, cost) in `TokiMonitor/Presentation/Popover/ProviderRowView.swift`
- [ ] T037 [P] [US2] Create TotalSummaryView (aggregate row, shown when 2+ providers) in `TokiMonitor/Presentation/Popover/TotalSummaryView.swift`
- [ ] T038 [US2] Create PopoverContentView composing provider rows + total + dashboard button in `TokiMonitor/Presentation/Popover/PopoverContentView.swift`
- [ ] T039 [US2] Wire NSPopover to StatusBarController click handler
- [ ] T040 [US2] Handle missing pricing: show token count only, "가격 정보 없음" label
- [ ] T041 [US2] Write ProviderRegistry tests in `TokiMonitor/Tests/TokiMonitorTests/Domain/ProviderRegistryTests.swift`
- [ ] T042 [US2] Write TokenAggregator provider grouping tests in `TokiMonitor/Tests/TokiMonitorTests/Domain/TokenAggregatorTests.swift`

**Acceptance Criteria**:
- [ ] 메뉴바 클릭 → 팝오버 200ms 이내 표시
- [ ] 프로바이더별 input/output 토큰 + 비용($) 표시
- [ ] 프로바이더 2개+ 시 상단 합산 행 표시
- [ ] 가격 미지원 프로바이더 → 토큰 수만 표시
- [ ] 시간 범위 변경 (30m/1h/today) 동작

**Deploy Check**: ✓ Yes — 팝오버만으로 독립 가치

---

## Phase 4: 상세 대시보드 (US3 - P2)

> **Purpose**: 기간별 리포트, 모델/세션 드릴다운, Swift Charts
> **User Story**: US3 - 상세 대시보드
> **Independent Test**: 대시보드 열기 → 기간 선택 → 차트/테이블 표시

### WP04: Dashboard Window (US3)

**Vertical Scope**: 대시보드 윈도우 + toki report 연동 + 차트

| Layer | Deliverable |
|-------|-------------|
| Data | TokiReportClient (daily/weekly/monthly queries) |
| Presentation | DashboardWindow, ReportView, ModelDetailView, UsageChartView |
| Test | TokiReportClient 응답 파싱 테스트 |

**Tasks**:
- [ ] T043 [US3] Extend TokiReportClient with daily/weekly/monthly/session queries in `TokiMonitor/Data/TokiReportClient.swift`
- [ ] T044 [US3] Create DashboardWindow with NSWindow management in `TokiMonitor/Presentation/Dashboard/DashboardWindow.swift`
- [ ] T045 [US3] Create ReportView with period selector (daily/weekly/monthly) in `TokiMonitor/Presentation/Dashboard/ReportView.swift`
- [ ] T046 [P] [US3] Create UsageChartView with Swift Charts (bar/line chart) in `TokiMonitor/Presentation/Dashboard/UsageChartView.swift`
- [ ] T047 [P] [US3] Create ModelDetailView for per-model drill-down in `TokiMonitor/Presentation/Dashboard/ModelDetailView.swift`
- [ ] T048 [US3] Wire popover "대시보드" button to open DashboardWindow
- [ ] T049 [US3] Write TokiReportClient response parsing tests in `TokiMonitor/Tests/TokiMonitorTests/Data/TokiReportClientTests.swift`

**Acceptance Criteria**:
- [ ] 팝오버 "대시보드" 클릭 → 대시보드 윈도우 열림
- [ ] 기간 선택 (일/주/월) → 리포트 1초 이내 표시
- [ ] 모델별 토큰/비용/호출수 테이블 + 차트 표시
- [ ] 모델 선택 → 세션별/프로젝트별 드릴다운

**Deploy Check**: ✓ Yes — 대시보드만으로 독립 가치

---

## Phase 5: Settings & Polish

> **Purpose**: 설정 뷰, Login at Boot, Dark/Light 모드, 성능 검증

### WP05: Settings & Cross-Cutting

**Vertical Scope**: 설정 UI + 시스템 통합 + 성능

| Area | Deliverable |
|------|-------------|
| Settings | SettingsView (animation style, time range, launch at login) |
| System | SMAppService login item, appearance mode |
| Performance | CPU/memory 프로파일링, 애니메이션 throttle |
| Polish | Dark/Light mode, empty states, error messages |

**Tasks**:
- [ ] T050 Create SettingsView with animation style picker, time range, launch at login toggle in `TokiMonitor/Presentation/Settings/SettingsView.swift`
- [ ] T051 Create AppSettings @Observable class with UserDefaults persistence in `TokiMonitor/Domain/AppSettings.swift`
- [ ] T052 Implement Login at Boot with SMAppService in `TokiMonitor/TokiMonitorApp.swift`
- [ ] T053 Add Dark/Light mode support to all views (system appearance tracking)
- [ ] T054 Implement animation throttle when popover is not visible in StatusBarController
- [ ] T055 Add empty state views (no events received yet) to PopoverContentView and DashboardWindow
- [ ] T056 Profile with Instruments: verify CPU <1% idle, memory <50MB
- [ ] T057 Add app icon and finalize Assets.xcassets

---

## Dependency Map

```
WP00 (Setup)
 │
 └──→ WP01 (US4: Connection) ──── Must complete first (all others need UDS)
       │
       ├──→ WP02 (US1: Animation) ─── Can deploy after WP01
       │
       ├──→ WP03 (US2: Popover) ──── Can deploy after WP01 (parallel with WP02)
       │     │
       │     └──→ WP04 (US3: Dashboard) ── Needs WP03 (report client, popover button)
       │
       └──→ WP05 (Polish) ────────── After all core slices
```

## Execution Strategy

### Sequential (Solo Developer)

```
WP00 → WP01 → WP02 → Deploy → WP03 → Deploy → WP04 → WP05 → Deploy
```

### Parallel Opportunities

Within each WP, tasks marked `[P]` can run in parallel:
- **WP02**: T021 (Character), T022 (Numeric), T023 (Sparkline) — 3종 동시
- **WP03**: T036 (ProviderRow), T037 (TotalSummary) — 2개 동시
- **WP04**: T046 (Chart), T047 (ModelDetail) — 2개 동시

### MVP First

```
WP00 → WP01 → WP02 → WP03 → STOP & VALIDATE → Deploy MVP
       (then continue with WP04, WP05...)
```

**MVP = US1 + US2 + US4**: 메뉴바 애니메이션 + 팝오버 요약 + 연결 관리

---

## Implementation Strategy

1. **WP00 먼저**: 빌드 가능한 빈 앱 확보
2. **WP01 (연결)**: 모든 기능의 기반 — toki UDS 통신
3. **WP02 + WP03 (병렬 가능)**: 메뉴바 애니메이션 + 팝오버
4. **WP04 (대시보드)**: MVP 이후, P2 우선순위
5. **WP05 (폴리시)**: 설정, 성능 최적화, 배포 준비

## Notes

- **Vertical Slice**: Each WP contains all layers needed for a feature
- **Independent Deploy**: Each completed WP can be deployed without others
- **Layer Labels**: Data → Domain → Presentation 순서로 구현
- **Dependencies**: WP01 blocks WP02-WP04; rest are parallel-capable
- **Walkthrough**: Each WP completion generates walkthrough for working memory
