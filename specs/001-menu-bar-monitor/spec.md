# Feature Specification: Menu Bar Token Monitor

**Feature Branch**: `001-menu-bar-monitor`
**Created**: 2026-03-17
**Status**: Draft
**Input**: 6-Pager 전략 문서 (`specs/strategy/6pager.md`)

## Clarifications

### Session 2026-03-17

- Q: toki 연동 방식 (UDS vs CLI vs FFI)? → A: UDS 직접 연결. 실시간 이벤트와 report 쿼리 모두 `~/.config/toki/daemon.sock` UDS로 통신. toki의 `send_report_query`가 UDS JSON 요청/응답을 지원함.
- Q: 최소 지원 macOS 버전? → A: macOS 14+ (Sonoma). Swift Charts, Observable 매크로 사용 가능.
- Q: 메뉴바 애니메이션 스타일? → A: 캐릭터(RunCat형), 수치, 미니 그래프(스파크라인) 3종 모두 지원. 설정에서 전환 가능. 캐릭터형은 프레임 교체 구조만 구현하고 플레이스홀더 이미지로 검증, 실제 에셋은 후속 삽입.
- Q: 팝오버 기본 시간 범위? → A: 최근 1시간 (기본값), 설정에서 변경 가능 (30분/1시간/오늘).
- Q: 팝오버에 전체 합산 행 표시? → A: 표시함. 프로바이더 2개 이상일 때 상단에 총 토큰/비용 합산 행 노출.

## User Scenarios & Testing

### User Story 1 - 실시간 메뉴바 토큰 애니메이션 (Priority: P1)

개발자가 AI 코딩 도구를 사용하는 동안, macOS 메뉴바의 아이콘 애니메이션을 통해
현재 토큰 소모 속도를 시각적으로 파악한다.

**Why this priority**: 제품의 핵심 가치이자 차별화 포인트. 이것만으로도 독립적 가치가 있음.

**Independent Test**: toki 데몬 실행 상태에서 Claude Code 사용 시 메뉴바 아이콘
애니메이션 속도 변화를 육안으로 확인 가능.

**Acceptance Scenarios**:

1. **Given** toki 데몬이 실행 중이고 AI 도구가 토큰을 소비할 때,
   **When** 토큰 이벤트가 UDS로 수신되면,
   **Then** 메뉴바 아이콘 애니메이션 속도가 소모율에 비례하여 변화

2. **Given** 토큰 이벤트가 없을 때(유휴 상태),
   **When** 일정 시간(예: 30초) 이벤트 없음,
   **Then** 아이콘이 정지 상태로 전환

3. **Given** 시스템이 Reduce Motion 설정을 활성화했을 때,
   **When** 토큰 이벤트 수신,
   **Then** 애니메이션 대신 정적 수치(토큰/분) 표시

---

### User Story 2 - 프로바이더별 사용량 팝오버 (Priority: P1)

메뉴바 아이콘을 클릭하면 팝오버가 나타나, 프로바이더별(Claude, Gemini 등)
최근 시간 동안의 토큰 사용량과 추정 비용을 요약한다.

**Why this priority**: 메뉴바 애니메이션과 함께 MVP의 핵심. 상세 데이터 없이
애니메이션만으로는 실용성이 부족.

**Independent Test**: 메뉴바 클릭 → 팝오버 표시 → 프로바이더별 수치 확인.

**Acceptance Scenarios**:

1. **Given** 메뉴바 아이콘 클릭 시,
   **When** 팝오버가 열리면,
   **Then** 각 프로바이더의 설정된 시간 범위(기본 1시간, 30분/오늘 선택 가능) 토큰 사용량(input/output)과 추정 비용($) 표시

2. **Given** 가격 데이터가 없는 프로바이더,
   **When** 해당 프로바이더 행 표시 시,
   **Then** 비용 대신 토큰 수만 표시하고 "가격 정보 없음" 표기

3. **Given** 팝오버에서 "대시보드" 버튼 클릭 시,
   **Then** 대시보드 윈도우가 열림

---

### User Story 3 - 상세 대시보드 (Priority: P2)

팝오버에서 "대시보드"를 클릭하면 별도 윈도우가 열리며, toki의 report 기능과
연동하여 기간별 세부 데이터(모델별, 세션별, 프로젝트별)를 분석할 수 있다.

**Why this priority**: MVP 이후 확장. 팝오버가 개요를 제공한다면 대시보드는
심층 분석을 담당.

**Independent Test**: 대시보드 단독으로 기간 선택 → 리포트 조회 → 데이터 표시 확인.

**Acceptance Scenarios**:

1. **Given** 대시보드 윈도우가 열렸을 때,
   **When** 기간(일간/주간/월간)을 선택하면,
   **Then** 해당 기간의 모델별 토큰 사용량, 비용, 호출 수가 테이블/차트로 표시

2. **Given** 대시보드에서 특정 모델을 선택할 때,
   **When** 드릴다운 뷰로 전환하면,
   **Then** 해당 모델의 세션별/프로젝트별 사용 내역이 표시

---

### User Story 4 - toki 데몬 연결 관리 (Priority: P1)

toki 데몬이 실행되지 않았을 때 이를 명확히 알리고, 원클릭으로 시작할 수 있어야 한다.

**Why this priority**: toki 데몬은 필수 의존성. 연결 상태 관리 없이는 앱이 무용지물.

**Independent Test**: toki 데몬 중지 → 앱 상태 변화 확인 → 원클릭 시작 → 재연결 확인.

**Acceptance Scenarios**:

1. **Given** toki 데몬이 미실행 상태일 때,
   **When** 앱이 연결을 시도하면,
   **Then** 메뉴바 아이콘이 "연결 끊김" 상태로 표시

2. **Given** "연결 끊김" 상태에서 메뉴바 클릭 시,
   **When** 팝오버에 "toki 시작" 버튼이 표시되고 클릭하면,
   **Then** `toki daemon start`가 실행되고 자동 재연결

3. **Given** toki 데몬이 실행 중 크래시할 때,
   **When** UDS 연결이 끊기면,
   **Then** 자동으로 재연결을 시도하고 (최대 3회, 5초 간격), 실패 시 "연결 끊김" 표시

---

### Edge Cases

- toki 데몬이 오래된 버전일 때 호환성 처리는?
- UDS 버퍼가 가득 찰 정도로 이벤트가 폭주하면?
- fjall DB 파일이 손상된 경우 대시보드 리포트 실패 처리는?
- 다크 모드 ↔ 라이트 모드 전환 시 아이콘/팝오버 즉시 반영?
- Login at boot (LaunchAgent) 설정 시 toki보다 먼저 시작되는 경우?

## Requirements

### Functional Requirements

- **FR-001**: 앱은 macOS 메뉴바에 NSStatusItem으로 상주해야 한다
- **FR-002**: toki UDS(`~/.config/toki/daemon.sock`)에 Swift NWConnection으로 연결하여 실시간 NDJSON 이벤트 수신 및 report JSON 쿼리/응답을 모두 처리해야 한다
- **FR-003**: 토큰 이벤트 발생 시 메뉴바 아이콘 애니메이션 속도를 토큰 처리량에 비례하여 조절해야 한다
- **FR-004**: 메뉴바 클릭 시 NSPopover로 프로바이더별 사용량 요약을 표시해야 한다
- **FR-005**: 팝오버에서 각 프로바이더의 input/output 토큰 수와 추정 비용(USD)을 표시해야 한다
- **FR-006**: toki의 LiteLLM 가격 데이터를 활용하여 비용을 계산해야 한다
- **FR-012**: 팝오버에서 프로바이더가 2개 이상일 때 상단에 전체 합산 행(총 토큰, 총 비용)을 표시해야 한다
- **FR-007**: 대시보드 윈도우에서 toki report 기능(daily/weekly/monthly)과 연동하여 이력 데이터를 표시해야 한다
- **FR-008**: toki 데몬 미실행 시 "연결 끊김" 상태를 표시하고 원클릭 시작을 제공해야 한다
- **FR-009**: 설정에서 애니메이션 스타일(캐릭터/수치/스파크라인 3종 전환), 기본 시간 범위, Login at boot 옵션을 제공해야 한다
- **FR-011**: 캐릭터 애니메이션은 프레임 이미지 배열을 교체 가능한 구조로 구현하여, 에셋 추가만으로 새 캐릭터를 삽입할 수 있어야 한다
- **FR-010**: 최소 배포 타겟은 macOS 14 (Sonoma)이며, Swift Charts 및 @Observable 매크로를 활용한다

### Key Entities

- **TokenEvent**: toki UsageEvent의 Swift 매핑 (model, input_tokens, output_tokens, cache_creation, cache_read, timestamp)
- **ProviderSummary**: 프로바이더별 집계 (provider_name, total_input, total_output, estimated_cost, event_count, time_range)
- **ConnectionState**: toki 데몬 연결 상태 (connected, disconnected, reconnecting)
- **AnimationState**: 메뉴바 애니메이션 상태 (idle, low, medium, high — 토큰 처리량 기반)
- **AnimationStyle**: 메뉴바 표시 모드 (character: 프레임 기반 캐릭터 애니메이션, numeric: "1.2K/m" 수치 표시, sparkline: 미니 그래프)

## Success Criteria

### Measurable Outcomes

- **SC-001**: toki 이벤트 수신 후 500ms 이내에 메뉴바 애니메이션에 반영
- **SC-002**: 유휴 시 CPU 사용률 1% 미만, 메모리 50MB 미만
- **SC-003**: 팝오버 열기 응답 시간 200ms 미만
- **SC-004**: 대시보드 리포트 쿼리 응답 시간 1초 미만 (toki 13ms + UI 렌더링)
- **SC-005**: toki 데몬 재시작 후 10초 이내 자동 재연결 성공
- **SC-006**: 다크 모드/라이트 모드 모두에서 UI 요소가 정상 렌더링
