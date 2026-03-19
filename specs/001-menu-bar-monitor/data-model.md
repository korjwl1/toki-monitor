# Data Model: Menu Bar Token Monitor

**Phase 1 Output** | **Updated**: 2026-03-19

## Entity Diagram

```
┌───────────────────────────┐     ┌─────────────────────────┐
│       TokenEvent          │     │    ProviderSummary       │
│───────────────────────────│     │─────────────────────────│
│ model: String             │────▶│ provider: ProviderInfo   │
│ source: String            │     │ totalInput: UInt64       │
│ inputTokens: UInt64       │     │ totalOutput: UInt64      │
│ outputTokens: UInt64      │     │ estimatedCost: Double?   │
│ cacheCreationInput: UInt64│     │ eventCount: Int          │
│ cacheReadInput: UInt64    │     └─────────────────────────┘
│ cachedInput: UInt64       │                │
│ reasoningOutput: UInt64   │                ▼
│ costUSD: Double?          │     ┌─────────────────────────┐
│ receivedAt: Date          │     │     TotalSummary         │
└───────────────────────────┘     │─────────────────────────│
                                  │ totalInput/Output: UInt64│
┌───────────────────────────┐     │ totalCost: Double?       │
│      ProviderInfo         │     │ providerCount: Int       │
│───────────────────────────│     └─────────────────────────┘
│ id: String                │
│ name: String              │
│ prefixes: [String]        │
│ schemas: [String]         │
│ icon: String (SF Symbol)  │
│ colorName: String         │
└───────────────────────────┘
```

## Entities

### TokenEvent (Data → Domain)

toki UDS에서 수신하는 개별 토큰 이벤트. 프로바이더별 필드는 Optional.

```swift
struct TokenEvent: Identifiable {
    let id: UUID
    let model: String
    let source: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheCreationInputTokens: UInt64  // Claude Code (0 if not present)
    let cacheReadInputTokens: UInt64      // Claude Code
    let cachedInputTokens: UInt64         // Codex (0 if not present)
    let reasoningOutputTokens: UInt64     // Codex
    let costUSD: Double?
    let receivedAt: Date
}
```

### ProviderInfo (Domain)

프로바이더 메타데이터. 모델 접두사 + toki schema 이름으로 매핑.

```swift
struct ProviderInfo: Identifiable {
    let id: String           // "anthropic", "openai", "google"
    let name: String         // "Claude", "OpenAI", "Gemini"
    let prefixes: [String]   // ["claude-"]
    let schemas: [String]    // ["claude_code"]
    let icon: String         // SF Symbol name
    let colorName: String    // → Presentation layer에서 Color로 변환
}
```

### ProviderSummary (Domain)

```swift
struct ProviderSummary: Identifiable, TokenUsageModel {
    let provider: ProviderInfo
    var totalInput: UInt64
    var totalOutput: UInt64
    var estimatedCost: Double?
    var eventCount: Int
}
```

### ConnectionState (Domain)

```swift
enum ConnectionState: Equatable {
    case connected
    case disconnected
    case reconnecting(attempt: Int, maxAttempts: Int)
}
```

연결 성공은 NWConnection `.ready` 콜백으로 확인.
재연결: 최대 3회, 5초 간격, 시도당 3초 타임아웃.

### AnimationState / AnimationStyle (Domain)

```swift
enum AnimationState: Int, Comparable {
    case idle = 0     // 0 tokens/min
    case low = 1      // 1-100 tokens/min
    case medium = 2   // 100-1000 tokens/min
    case high = 3     // 1000+ tokens/min
}

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // 7-frame rabbit animation
    case numeric     // "1.2K/m" text
    case sparkline   // mini graph
}
```

### TimeRange (Domain)

```swift
enum TimeRange: String, CaseIterable, Codable {
    case thirtyMinutes = "30m"
    case oneHour = "1h"       // default
    case today = "today"
}
```

### AppSettings (Domain)

```swift
@Observable class AppSettings {
    var animationStyle: AnimationStyle = .sparkline
    var defaultTimeRange: TimeRange = .oneHour
    var launchAtLogin: Bool = false
}
```

UserDefaults 저장. Login at Boot은 SMAppService.

### SchemaTaggedSummary (Data)

toki report 응답의 per-provider 결과. Data 레이어에서만 사용.

```swift
struct SchemaTaggedSummary {
    let schema: String          // "claude_code", "codex"
    let summaries: [TokiModelSummary]
}
```

### TokenFormatter (Domain)

포맷팅 유틸. 모든 뷰에서 공유.

```swift
enum TokenFormatter {
    static func formatTokens(_ count: UInt64) -> String
    static func formatCost(_ cost: Double) -> String
    static func formatRate(_ tokensPerMinute: Double) -> String
}
```

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
    │◀──SchemaTaggedSummary──────────┘
    │           │
    │    ProviderRegistry.resolveSchema()
    ▼
DashboardView (Swift Charts)
```
