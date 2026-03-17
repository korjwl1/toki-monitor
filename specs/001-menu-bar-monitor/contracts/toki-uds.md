# Contract: toki UDS Protocol

**Version**: 1.0 | **Date**: 2026-03-17
**Socket**: `~/.config/toki/daemon.sock` (Unix Domain Socket)

## Connection Discrimination

클라이언트 연결 후 200ms 이내에 첫 줄을 읽어 모드를 결정:

```
Connect → Read first line (200ms timeout)
  ├─ Valid JSON received → REPORT mode
  └─ Timeout / non-JSON  → TRACE mode
```

## TRACE Mode (Streaming)

### Connection

1. UDS 연결
2. 아무 데이터도 보내지 않음 (200ms 대기)
3. 서버가 NDJSON 스트리밍 시작
4. 연결 유지 (무한)

### Event Message

```typescript
interface TraceEvent {
  type: "event";
  data: {
    model: string;                        // e.g. "claude-opus-4-6"
    source: string;                       // session UUID prefix (8 chars) or "uuid/agent-id"
    input_tokens: number;
    output_tokens: number;
    cache_creation_input_tokens: number;
    cache_read_input_tokens: number;
    cost_usd?: number;                    // optional, only if pricing available
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
  tz?: string;     // IANA timezone, e.g. "Asia/Seoul" (null = UTC)
}
```

### Response (Success)

```typescript
interface ReportResponse {
  ok: true;
  data: ReportItem[];
}

interface ReportItem {
  type: "summary" | "hourly" | "daily" | "weekly" | "monthly" | "yearly" | "session" | "sessions" | "projects";
  data?: ModelSummary[];  // for summary/grouped types
  items?: string[];       // for sessions/projects list types
}

interface ModelSummary {
  model: string;
  input_tokens: number;
  output_tokens: number;
  cache_creation_input_tokens: number;
  cache_read_input_tokens: number;
  total_tokens: number;
  events: number;
  cost_usd?: number;
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
key       := "model" | "session" | "project"
bucket    := "1h" | "1d" | "1w" | "1M" | "1y"
```

**Examples**:

| Query | Description |
|-------|-------------|
| `usage` | 전체 모델 요약 |
| `usage[1h]` | 시간별 그룹 |
| `usage[1d]` | 일별 그룹 |
| `usage{model="claude-opus-4-6"}[1d]` | 특정 모델 일별 |
| `usage{project="toki-monitor"}` | 프로젝트 필터 |
| `sessions` | 세션 ID 목록 |
| `projects` | 프로젝트 목록 |

### Connection Lifecycle

1. UDS 연결
2. JSON 요청 전송 (단일 줄 + `\n`)
3. 응답 수신 (단일 줄 JSON)
4. 연결 종료

**타임아웃**: 응답 대기 60초

## Swift Client Implementation Notes

### Trace Client

```swift
// 1. Connect to UDS
// 2. Do NOT send anything (let 200ms timeout expire on server)
// 3. Start receiving NDJSON lines
// 4. Buffer incoming data, split on \n, decode each line
```

### Report Client

```swift
// 1. Connect to UDS
// 2. Immediately send: {"query":"usage[1h]","tz":"Asia/Seoul"}\n
// 3. Read single line response
// 4. Decode as ReportResponse
// 5. Close connection
```

### Provider Mapping (Client-Side)

toki는 provider 필드를 전송하지 않음. `model` 접두사로 매핑:

| Prefix | Provider |
|--------|----------|
| `claude-` | Anthropic |
| `gemini-` | Google |
| `gpt-`, `o1-`, `o3-`, `o4-` | OpenAI |
