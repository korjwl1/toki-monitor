# Implementation Plan: Menu Bar Token Monitor

**Branch**: `001-menu-bar-monitor` | **Date**: 2026-03-17 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-menu-bar-monitor/spec.md`

## Summary

macOS 메뉴바에 상주하면서 toki 데몬과 UDS로 통신하여 AI 토큰 사용량을
실시간 애니메이션(캐릭터/수치/스파크라인 3종)으로 시각화하고, 팝오버로
프로바이더별 요약을 표시하며, 대시보드 윈도우에서 이력 데이터를 분석하는
Swift/SwiftUI 네이티브 앱.

## Technical Context

**Language/Version**: Swift 6.0+ / SwiftUI (macOS 14+ Sonoma)
**Primary Dependencies**: SwiftUI, AppKit (NSStatusItem, NSPopover), Network.framework (NWConnection for UDS), Swift Charts
**Storage**: UserDefaults (설정), toki fjall TSDB (데이터는 toki 소유, 앱은 읽기만)
**Testing**: XCTest, Swift Testing
**Target Platform**: macOS 14+ (Sonoma)
**Project Type**: single (macOS app)
**Performance Goals**: 이벤트 반영 <500ms, 유휴 CPU <1%, 메모리 <50MB, 팝오버 <200ms
**Constraints**: UDS 통신 전용 (CLI/FFI 없음), toki 데몬 필수 의존
**Scale/Scope**: 단일 사용자, 프로바이더 2-5개, 이벤트 ~수천/일

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| 1. Native macOS Experience | ✅ Pass | NSStatusItem + NSPopover + SwiftUI, Dark/Light/Reduce Motion 대응 |
| 2. Minimal Resource Footprint | ✅ Pass | 이벤트 기반 UDS (폴링 없음), 애니메이션 throttle 설계 |
| 3. toki Integration First | ✅ Pass | UDS 전용, 데이터 저장 없음, 프로바이더 = toki LogParser |
| 4. Provider-Agnostic Architecture | ✅ Pass | TokenUsageModel 프로토콜, 모델명 기반 프로바이더 매핑 |
| 5. Clear Layered Structure | ✅ Pass | Data/Domain/Presentation 3레이어, 의존성 내향 |
| 6. Testing at Boundaries | ✅ Pass | UDS mock, 도메인 유닛 테스트, UI 테스트 계획 |
| 7. Progressive Disclosure | ✅ Pass | 메뉴바 → 팝오버 → 대시보드 3단계 |
| 8. Graceful Degradation | ✅ Pass | 연결 상태 관리, 빈 상태 UI, 자동 재연결 |

## Project Structure

### Documentation (this feature)

```text
specs/001-menu-bar-monitor/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: UDS 프로토콜, SwiftUI 기술 리서치
├── data-model.md        # Phase 1: 엔티티, 상태 머신
├── contracts/           # Phase 1: toki UDS 프로토콜 명세
│   └── toki-uds.md
├── quickstart.md        # Phase 1: 빌드 & 실행 가이드
└── tasks.md             # Phase 2: /spec-mix.tasks 출력
```

### Source Code (repository root)

```text
TokiMonitor/
├── TokiMonitorApp.swift              # @main, App lifecycle
├── Info.plist                         # LSUIElement = true (Dock 숨김)
│
├── Data/                              # Data Layer (toki 통신)
│   ├── TokiConnection.swift           # NWConnection UDS 클라이언트
│   ├── TokiEventStream.swift          # NDJSON 실시간 이벤트 파서
│   ├── TokiReportClient.swift         # Report 쿼리 요청/응답
│   └── Models/
│       ├── TokiEvent.swift            # {"type":"event","data":{...}} Codable
│       ├── TokiReportRequest.swift    # {"query":"...","tz":"..."} Codable
│       └── TokiReportResponse.swift   # {"ok":true,"data":[...]} Codable
│
├── Domain/                            # Domain Layer (비즈니스 로직)
│   ├── TokenUsageModel.swift          # 프로바이더-무관 토큰 사용 프로토콜
│   ├── ProviderSummary.swift          # 프로바이더별 집계 모델
│   ├── ProviderRegistry.swift         # 모델명 → 프로바이더 매핑 (데이터 기반)
│   ├── TokenAggregator.swift          # 시간 범위별 이벤트 집계
│   ├── AnimationStateMapper.swift     # 토큰 처리량 → AnimationState 변환
│   └── ConnectionManager.swift        # 연결 상태 머신, 재연결 로직
│
├── Presentation/                      # Presentation Layer (SwiftUI)
│   ├── MenuBar/
│   │   ├── StatusBarController.swift  # NSStatusItem + NSPopover 관리 (AppKit)
│   │   ├── CharacterAnimationView.swift  # 프레임 기반 캐릭터 애니메이션
│   │   ├── NumericBadgeView.swift     # "1.2K/m" 수치 표시
│   │   └── SparklineView.swift        # 미니 그래프
│   ├── Popover/
│   │   ├── PopoverContentView.swift   # 팝오버 메인 뷰
│   │   ├── ProviderRowView.swift      # 프로바이더별 사용량 행
│   │   ├── TotalSummaryView.swift     # 전체 합산 행
│   │   └── DisconnectedView.swift     # 연결 끊김 상태 뷰
│   ├── Dashboard/
│   │   ├── DashboardWindow.swift      # 대시보드 윈도우
│   │   ├── ReportView.swift           # 기간별 리포트 뷰
│   │   ├── ModelDetailView.swift      # 모델 드릴다운 뷰
│   │   └── UsageChartView.swift       # Swift Charts 차트
│   └── Settings/
│       └── SettingsView.swift         # 설정 뷰
│
├── Resources/
│   ├── Assets.xcassets/               # 아이콘, 캐릭터 프레임
│   └── Localizable.strings            # (향후) 다국어
│
└── Tests/
    ├── TokiMonitorTests/
    │   ├── Data/
    │   │   ├── TokiEventStreamTests.swift
    │   │   └── TokiReportClientTests.swift
    │   ├── Domain/
    │   │   ├── TokenAggregatorTests.swift
    │   │   ├── AnimationStateMapperTests.swift
    │   │   └── ProviderRegistryTests.swift
    │   └── Integration/
    │       └── UDSConnectionTests.swift
    └── TokiMonitorUITests/
        └── PopoverUITests.swift
```

**Structure Decision**: 단일 macOS 앱 프로젝트. Data/Domain/Presentation 3레이어 구조로
Constitution 원칙 5(Clear Layered Structure)를 준수. Xcode 프로젝트 내 폴더 그룹으로 구성.

## Complexity Tracking

> No constitution violations detected. All 8 principles satisfied.
