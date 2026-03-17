# Data Model: Menu Bar Token Monitor

**Phase 1 Output** | **Date**: 2026-03-17

## Entity Diagram

```
┌─────────────────────┐     ┌─────────────────────┐
│     TokenEvent      │     │   ProviderSummary    │
│─────────────────────│     │─────────────────────│
│ model: String       │────▶│ providerName: String │
│ source: String      │     │ providerIcon: String │
│ inputTokens: UInt64 │     │ providerColor: Color │
│ outputTokens: UInt64│     │ totalInput: UInt64   │
│ cacheCreation: UInt64│    │ totalOutput: UInt64  │
│ cacheRead: UInt64   │     │ estimatedCost: Double?│
│ costUSD: Double?    │     │ eventCount: Int      │
│ timestamp: Date     │     │ timeRange: TimeRange │
└─────────────────────┘     └─────────────────────┘
                                      │
                                      ▼
                            ┌─────────────────────┐
                            │    TotalSummary      │
                            │─────────────────────│
                            │ totalInput: UInt64   │
                            │ totalOutput: UInt64  │
                            │ totalCost: Double?   │
                            │ providerCount: Int   │
                            └─────────────────────┘
```

## Entities

### TokenEvent (Data Layer)

toki UDS에서 수신하는 개별 토큰 이벤트의 Swift 매핑.

```swift
struct TokenEvent: Codable, Identifiable {
    let id: UUID  // 클라이언트 생성
    let model: String
    let source: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64
    let cacheReadInputTokens: UInt64
    let costUSD: Double?
    let receivedAt: Date  // 클라이언트 수신 시각
}
```

**생명주기**: 수신 → 집계 버퍼에 추가 → 시간 범위 초과 시 삭제
**고유성**: `id` (클라이언트 생성 UUID). toki는 dedup 처리 후 전송하므로 중복 없음.

### ProviderSummary (Domain Layer)

특정 시간 범위에서의 프로바이더별 집계.

```swift
struct ProviderSummary: Identifiable {
    let id: String  // providerName
    let providerName: String
    let providerIcon: String  // SF Symbol name
    let providerColor: Color
    var totalInput: UInt64
    var totalOutput: UInt64
    var estimatedCost: Double?
    var eventCount: Int
    let timeRange: TimeRange
}
```

**생명주기**: 팝오버 열기 시 생성 → 이벤트 수신 시 갱신 → 시간 범위 변경 시 재생성

### ProviderInfo (Domain Layer)

프로바이더 메타데이터 (데이터 기반, 하드코딩 아님).

```swift
struct ProviderInfo {
    let name: String         // "Anthropic"
    let modelPrefixes: [String]  // ["claude-"]
    let icon: String         // "brain.head.profile"
    let color: Color         // .purple
}
```

**저장**: 앱 번들 내 JSON/plist 또는 코드 내 static 배열. 새 프로바이더 추가 시 이 배열만 수정.

### AnimationStyle (Domain Layer)

```swift
enum AnimationStyle: String, CaseIterable, Codable {
    case character   // 프레임 기반 캐릭터
    case numeric     // "1.2K/m" 텍스트
    case sparkline   // 미니 그래프
}
```

### AnimationState (Domain Layer)

```swift
enum AnimationState: Int, Comparable {
    case idle = 0    // 0 tokens/min
    case low = 1     // 1-100 tokens/min
    case medium = 2  // 100-1000 tokens/min
    case high = 3    // 1000+ tokens/min
}
```

**임계값**: 설정에서 조절 가능하게 하되 기본값은 위와 같음.
**매핑 로직**: `AnimationStateMapper`가 최근 N초간 토큰 처리량 → AnimationState 변환.

### ConnectionState (Domain Layer)

```swift
enum ConnectionState {
    case connected
    case disconnected
    case reconnecting(attempt: Int, maxAttempts: Int)
}
```

**상태 전이**:

```
                    ┌──────────┐
        App Start ──▶ disconnected │
                    └─────┬────┘
                          │ connect()
                          ▼
                    ┌──────────┐
                    │ connected  │◀─── reconnect success
                    └─────┬────┘
                          │ UDS error / EOF
                          ▼
                    ┌──────────────────┐
                    │ reconnecting(1,3) │──▶ reconnecting(2,3) ──▶ reconnecting(3,3)
                    └──────────────────┘                                   │
                          ▲                                                │ all failed
                          │ reconnect success                              ▼
                          │                                          ┌──────────┐
                          └──────────────────────────────────────────│disconnected│
                                                                     └──────────┘
```

- 최대 3회 재연결, 5초 간격
- 모든 재연결 실패 시 disconnected로 전환
- disconnected에서 사용자가 "toki 시작" 클릭 시 → `toki daemon start` 실행 → connect()

### TimeRange (Domain Layer)

```swift
enum TimeRange: String, CaseIterable, Codable {
    case thirtyMinutes = "30m"
    case oneHour = "1h"       // default
    case today = "today"
}
```

### AppSettings (Presentation Layer)

```swift
@Observable
class AppSettings {
    var animationStyle: AnimationStyle = .sparkline
    var defaultTimeRange: TimeRange = .oneHour
    var launchAtLogin: Bool = false
}
```

**저장**: `UserDefaults` (앱 고유 suite)

## Data Flow

```
toki daemon
    │
    │ UDS (NDJSON stream)
    ▼
TokiEventStream ──parse──▶ TokenEvent
    │                           │
    │                    ProviderRegistry.resolve(model)
    │                           │
    ▼                           ▼
TokenAggregator ──aggregate──▶ [ProviderSummary]
    │                               │
    │                        TotalSummary (if 2+ providers)
    │                               │
    ▼                               ▼
AnimationStateMapper          PopoverContentView
    │                         DashboardWindow
    ▼
StatusBarController (animation speed/style)
```

```
User clicks "Dashboard"
    │
    ▼
TokiReportClient ──query UDS──▶ toki daemon
    │                                │
    │◀───────JSON response───────────┘
    │
    ▼
ReportView / UsageChartView (Swift Charts)
```
