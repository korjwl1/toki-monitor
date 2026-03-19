# Contract: toki UDS Protocol

**Version**: 2.0 | **Date**: 2026-03-19
**Socket**: `~/.config/toki/daemon.sock` (Unix Domain Socket)

## Connection Protocol

클라이언트가 첫 줄로 명령어를 전송하여 모드를 선언:

```
Connect → Send command as first line
  ├─ "TRACE\n"  → TRACE mode (streaming)
  └─ "REPORT\n" → REPORT mode (request/response)
```

## TRACE Mode (Streaming)

### Connection

1. UDS 연결
2. `TRACE\n` 전송
3. 서버가 NDJSON 스트리밍 시작
4. 연결 유지 (무한)

### Event Message

```typescript
interface TraceEvent {
  type: "event";
  data: {
    model: string;
    source: string;
    provider?: string;              // "Claude Code", "Codex CLI"
    timestamp?: string;             // ISO 8601 from session file
    input_tokens: number;
    output_tokens: number;
    total_tokens?: number;
    cost_usd?: number;
    // Claude Code specific
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
    // Codex specific
    cached_input_tokens?: number;
    reasoning_output_tokens?: number;
  };
}
```

### Behavior

- 각 이벤트는 `\n`으로 구분된 독립 JSON 라인 (NDJSON)
- 쓰기 실패 시 클라이언트 자동 제거 (에러 미전송)
- 쓰기 타임아웃: 1초
- 클라이언트 0개일 때 emit은 no-op

## REPORT Mode (Request/Response)

### Request

```typescript
interface ReportRequest {
  query: string;   // PromQL-style query
  tz?: string;     // IANA timezone (null = UTC)
}
```

### Response (Success)

각 응답 항목은 `schema` 필드로 프로바이더 태깅됨:

```typescript
interface ReportResponse {
  ok: true;
  data: ReportItem[];
}

interface ReportItem {
  type: "summary" | "hour" | "day" | "week" | "session" | "sessions" | "projects";
  schema?: string;              // "claude_code" | "codex" (per-provider tagging)
  data?: ModelSummary[];        // for summary/grouped types
  items?: string[];             // for sessions/projects list types
}

interface ModelSummary {
  model: string;
  input_tokens: number;
  output_tokens: number;
  total_tokens: number;
  events: number;
  cost_usd?: number;
  // Claude Code specific
  cache_creation_input_tokens?: number;
  cache_read_input_tokens?: number;
  // Codex specific
  cached_input_tokens?: number;
  reasoning_output_tokens?: number;
}
```

### Response (Error)

```typescript
interface ReportErrorResponse {
  ok: false;
  error: string;
}
```

### Query Syntax

```
<metric>{<filters>}[<bucket>]

metric    := "usage" | "sessions" | "projects"
filters   := key="value" [, key="value"]*
key       := "model" | "session" | "project" | "provider"
bucket    := "1h" | "1d" | "1w" | "30d"
```

**Examples**:

| Query | Description |
|-------|-------------|
| `usage` | 전체 모델 요약 |
| `usage[1h]` | 시간별 그룹 |
| `usage[1d]` | 일별 그룹 |
| `usage{provider="codex"}[1d]` | Codex만 일별 |
| `usage{model="claude-opus-4-6"}[1d]` | 특정 모델 일별 |
| `sessions` | 세션 ID 목록 |
| `projects` | 프로젝트 목록 |

### Supported Providers (schema)

| Schema | Provider | Model Prefixes |
|--------|----------|---------------|
| `claude_code` | Anthropic (Claude) | `claude-` |
| `codex` | OpenAI (Codex CLI) | `gpt-`, `o1-`, `o3-`, `o4-` |

### Connection Lifecycle

**Trace**: 연결 → `TRACE\n` 전송 → 스트리밍 시작 → 무한
**Report**: 연결 → `REPORT\n` 전송 → JSON 쿼리 전송 → 응답 수신 → 연결 종료

## Swift Client Implementation Notes

### Trace Client

```swift
// 1. Connect to UDS (NWConnection)
// 2. Send: "TRACE\n"
// 3. Wait for onReady callback → connected
// 4. Receive NDJSON lines, decode TokiEventEnvelope
// 5. Events include provider and timestamp fields
```

### Report Client

```swift
// 1. Connect to UDS
// 2. Send: "REPORT\n"
// 3. Send: {"query":"usage[1h]","tz":"Asia/Seoul"}\n
// 4. Read single line response → TokiReportResponse
// 5. Each item tagged with schema → resolve via ProviderRegistry.resolveSchema()
```
