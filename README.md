# Toki Monitor

AI 토큰 사용량을 실시간으로 모니터링하는 macOS 메뉴바 앱.

[toki](https://github.com/user/toki) 데몬과 연동하여 Claude Code, Gemini CLI 등 AI 코딩 도구의 토큰 소모율과 비용을 한눈에 보여줍니다.

## Features

### Menu Bar Animation

토큰 소모 속도에 따라 메뉴바 아이콘이 반응합니다. 3종 스타일 지원:

| Style | Description |
|-------|-------------|
| **Sparkline** | 미니 그래프로 최근 토큰 추이 표시 (기본값) |
| **Numeric** | `1.2K/m` 형태의 수치 표시 |
| **Character** | RunCat 스타일 프레임 애니메이션 |

### Provider Summary Popover

메뉴바 클릭 시 팝오버에서:
- 프로바이더별(Claude, Gemini, OpenAI) 토큰 사용량 + 추정 비용
- 2개 이상 프로바이더 사용 시 전체 합산 행
- 시간 범위 전환 (30분 / 1시간 / 오늘)

### Dashboard

팝오버에서 대시보드 버튼 클릭 시:
- 기간별(일간/주간/월간) 리포트
- 모델별 토큰 분포 Swift Charts
- 모델 드릴다운 (세션별/프로젝트별)

### Connection Management

- toki 데몬 미실행 시 "연결 끊김" 상태 표시
- 원클릭 데몬 시작
- 자동 재연결 (최대 3회, 5초 간격)

## Requirements

- **macOS 14+ (Sonoma)**
- **Xcode 15.2+** (빌드 시)
- **toki** CLI 설치 필요

## Install

### Homebrew (예정)

```bash
brew tap <user>/toki-monitor
brew install --cask toki-monitor
```

### Build from Source

```bash
# Clone
git clone https://github.com/<user>/toki-monitor.git
cd toki-monitor

# xcodegen 필요 (프로젝트 생성)
brew install xcodegen
xcodegen generate

# Xcode에서 빌드 & 실행
open TokiMonitor.xcodeproj
# Cmd+R
```

또는 CLI에서:

```bash
xcodebuild build -project TokiMonitor.xcodeproj -scheme TokiMonitor -destination 'platform=macOS'
```

## Usage

### 1. toki 데몬 시작

```bash
toki daemon start
```

### 2. 앱 실행

Xcode에서 `Cmd+R` 또는 빌드된 `.app`을 실행합니다.

### 3. AI 도구 사용

Claude Code, Gemini CLI 등을 사용하면 메뉴바에서 실시간으로 토큰 소모가 반영됩니다.

## Architecture

```
TokiMonitor/
├── Data/               # toki UDS 통신
│   ├── TokiConnection  # NWConnection UDS 클라이언트
│   ├── TokiEventStream # NDJSON 실시간 이벤트 파서
│   └── TokiReportClient # Report 쿼리 클라이언트
├── Domain/             # 비즈니스 로직
│   ├── ConnectionManager    # 연결 상태 머신
│   ├── TokenAggregator      # Rate 계산, 프로바이더 집계
│   ├── ProviderRegistry     # 모델명 → 프로바이더 매핑
│   └── AnimationStateMapper # 토큰율 → 애니메이션 상태
└── Presentation/       # SwiftUI + AppKit 뷰
    ├── MenuBar/        # NSStatusItem, 3종 렌더러
    ├── Popover/        # 프로바이더 요약, 연결 상태
    ├── Dashboard/      # 리포트 윈도우, Swift Charts
    └── Settings/       # 스타일, 시간 범위, Login at Boot
```

**의존성 방향**: Presentation → Domain → Data

toki 데몬과의 통신은 Unix Domain Socket(UDS)으로 이루어지며, 실시간 이벤트는 NDJSON 스트리밍, 리포트 쿼리는 JSON 요청/응답 방식입니다.

## toki Integration

Toki Monitor는 [toki](https://github.com/user/toki) 데몬의 프레젠테이션 레이어입니다.

- **실시간 이벤트**: `~/.config/toki/daemon.sock`에 연결, 200ms 무응답 → trace 클라이언트로 분류
- **리포트 쿼리**: 동일 소켓에 JSON 요청 전송 → report 클라이언트로 분류
- **가격 데이터**: toki가 LiteLLM에서 가져온 가격 데이터를 사용

## Settings

| 설정 | 옵션 | 기본값 |
|------|------|--------|
| 메뉴바 스타일 | 캐릭터 / 수치 / 그래프 | 그래프 |
| 시간 범위 | 30분 / 1시간 / 오늘 | 1시간 |
| 로그인 시 시작 | On / Off | Off |

## Testing

```bash
xcodebuild test -project TokiMonitor.xcodeproj -scheme TokiMonitor -destination 'platform=macOS'
```

34개 테스트 (7 suites):
- NDJSON 이벤트 파싱 (Claude + Codex 필드)
- Report 응답 디코딩 (per-provider schema 태깅)
- ConnectionState 상태 전이
- AnimationStateMapper 임계값
- TokenFormatter 포맷팅
- ProviderRegistry 모델/schema 매핑
- ProviderSummary 집계

## Supported Providers

| Provider | toki Schema | Model Prefix | Status |
|----------|------------|-------------|--------|
| Anthropic (Claude) | `claude_code` | `claude-` | ✅ Supported |
| OpenAI (Codex CLI) | `codex` | `gpt-`, `o1-`, `o3-` | ✅ Supported |
| Google (Gemini) | `gemini_cli` | `gemini-` | ⏳ Ready (toki parser 필요) |

새 프로바이더 추가: toki에 `LogParser` 구현 → Toki Monitor UI 변경 불필요.

## License

MIT
