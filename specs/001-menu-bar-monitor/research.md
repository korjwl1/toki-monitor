# Research: Menu Bar Token Monitor

**Phase 0 Output** | **Date**: 2026-03-17

## R1: toki UDS 프로토콜

### 결론

toki 데몬은 `~/.config/toki/daemon.sock`에서 UDS를 통해 두 가지 모드를 지원:

1. **Trace 모드 (스트리밍)**: 연결 후 200ms 동안 아무것도 보내지 않으면 trace 클라이언트로 분류. NDJSON 이벤트가 무한 스트리밍됨.
2. **Report 모드 (요청/응답)**: 연결 직후 JSON 요청을 보내면 report 클라이언트로 분류. 단일 JSON 응답 후 연결 종료.

### 프로토콜 판별 메커니즘

```
Client connects → Daemon reads first line (200ms timeout)
  ├─ First line is JSON → Report client (request/response)
  └─ Timeout or non-JSON → Trace client (streaming)
```

**Swift 구현 시사점**: 두 개의 별도 NWConnection이 필요.
- Trace용: 연결 후 즉시 수신 대기 (아무것도 보내지 않음)
- Report용: 연결 → JSON 전송 → 응답 수신 → 연결 종료

### Trace 이벤트 JSON 구조

```json
{
  "type": "event",
  "data": {
    "model": "claude-opus-4-6",
    "source": "4de9291e",
    "input_tokens": 3,
    "output_tokens": 14,
    "cache_creation_input_tokens": 5139,
    "cache_read_input_tokens": 9631,
    "cost_usd": 0.00123
  }
}
```

- `cost_usd`는 가격 데이터가 있을 때만 포함 (Optional)
- `source`는 세션 UUID의 처음 8자 또는 서브에이전트 경로

### Report 쿼리 구조

**요청**:
```json
{"query": "usage{model=\"claude-opus-4-6\"}[1h]", "tz": "Asia/Seoul"}
```

**응답 (성공)**:
```json
{
  "ok": true,
  "data": [{
    "type": "summary",
    "data": [{
      "model": "claude-opus-4-6",
      "input_tokens": 100,
      "output_tokens": 50,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0,
      "total_tokens": 150,
      "events": 5,
      "cost_usd": 0.00123
    }]
  }]
}
```

**응답 (에러)**:
```json
{"ok": false, "error": "query parse error: unknown metric"}
```

### 쿼리 문법 (PromQL-style)

| 쿼리 | 설명 |
|------|------|
| `usage` | 전체 요약 |
| `usage[1h]` | 시간별 버킷 |
| `usage[1d]` | 일별 버킷 |
| `usage[1w]` | 주별 버킷 |
| `usage{model="claude-opus-4-6"}` | 모델 필터 |
| `usage{session="abc123"}` | 세션 필터 |
| `usage{project="my-project"}` | 프로젝트 필터 |
| `sessions` | 세션 목록 |
| `projects` | 프로젝트 목록 |

### 연결 생명주기

- Trace 클라이언트: 무한 스트리밍, 쓰기 실패 시 자동 제거
- Report 클라이언트: 전용 스레드, 60초 타임아웃
- Broadcast sink: 클라이언트 없으면 zero overhead

## R2: Swift에서 UDS 연결

### NWConnection (Network.framework)

macOS 14+에서 `NWConnection`은 Unix Domain Socket을 지원:

```swift
let params = NWParameters()
let endpoint = NWEndpoint.unix(path: socketPath)
let connection = NWConnection(to: endpoint, using: params)
```

**장점**: 비동기, GCD 기반, 시스템 레벨 최적화
**단점**: UDS에서 line-based 읽기가 기본 지원되지 않으므로 NDJSON 파서 직접 구현 필요

### 대안: Foundation의 FileHandle/SocketPort

- `FileHandle`로 UDS 연결 가능하나, 비동기 패턴이 NWConnection보다 구식
- NWConnection 채택 결정

### NDJSON 파싱 전략

수신 데이터를 버퍼에 누적하고 `\n` 기준으로 분리:

```
Buffer: "{"type":"event"...}\n{"type":"ev"
→ 완성된 첫 줄 파싱 → 나머지는 버퍼에 보관
```

## R3: NSStatusItem + 애니메이션

### NSStatusItem 기본 구조

```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(named: "frame0")
```

### 애니메이션 3종 구현 방식

| 스타일 | 구현 | 메뉴바 표시 |
|--------|------|------------|
| Character | Timer로 NSImage 프레임 교체, 속도 = 토큰율 | 캐릭터 이미지 |
| Numeric | NSAttributedString 갱신 | "1.2K/m" 텍스트 |
| Sparkline | NSImage에 CGContext로 미니 그래프 그리기 | 작은 그래프 |

**Reduce Motion 대응**: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
체크 → true이면 강제 Numeric 모드

### NSPopover

```swift
let popover = NSPopover()
popover.contentViewController = NSHostingController(rootView: PopoverContentView())
popover.behavior = .transient // 외부 클릭 시 자동 닫힘
```

**SwiftUI 통합**: `NSHostingController`로 SwiftUI 뷰를 NSPopover에 임베드

## R4: 프로바이더 식별

### 모델명 기반 매핑

toki는 별도의 provider 필드를 전송하지 않음. 모델명 접두사로 판별:

| 접두사 | 프로바이더 |
|--------|-----------|
| `claude-` | Anthropic (Claude) |
| `gemini-` | Google (Gemini) |
| `gpt-` | OpenAI |
| `o1-`, `o3-`, `o4-` | OpenAI |

**구현**: `ProviderRegistry`에서 정규식/접두사 매칭으로 데이터 기반 처리.
하드코딩 대신 설정 파일 또는 plist로 매핑 테이블 관리 가능.

## R5: 앱 생명주기 (LSUIElement)

### Dock 아이콘 숨기기

`Info.plist`에 `LSUIElement = YES` 설정:
- Dock에 아이콘 미표시
- Cmd+Tab에 미노출
- 메뉴바 전용 앱으로 동작

### Login at Boot

`SMAppService.mainApp.register()` (macOS 13+)로 로그인 시 자동 시작.
기존 LaunchAgent 방식보다 간단하고 시스템 설정에 통합됨.

## R6: Homebrew Cask 배포

### 배포 파이프라인

1. Xcode Archive → Export .app
2. 코드 사이닝 + 노터라이제이션 (Apple Developer ID)
3. .app를 ZIP으로 패키징
4. GitHub Releases에 업로드
5. Homebrew Cask formula 작성 → homebrew-cask 또는 자체 tap

### 자체 Homebrew Tap (초기)

```ruby
cask "toki-monitor" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/user/toki-monitor/releases/download/v#{version}/TokiMonitor.zip"
  name "Toki Monitor"
  homepage "https://github.com/user/toki-monitor"
  app "TokiMonitor.app"
end
```

경쟁자(ClaudeBar, Stats)도 동일한 방식으로 배포 중.
