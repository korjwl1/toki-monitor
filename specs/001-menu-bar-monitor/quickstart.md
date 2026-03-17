# Quickstart: Toki Monitor

## Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15.2+
- toki CLI 설치 및 데몬 실행

### toki 설치 확인

```bash
# toki가 설치되어 있는지 확인
toki --version

# 데몬 시작
toki daemon start

# 데몬 상태 확인
toki daemon status
```

## Build & Run

### 1. Clone & Open

```bash
git clone https://github.com/<user>/toki-monitor.git
cd toki-monitor
open TokiMonitor.xcodeproj
```

### 2. Xcode에서 실행

1. Scheme: `TokiMonitor`
2. Target: My Mac
3. `Cmd+R`로 빌드 & 실행

### 3. 메뉴바 확인

- 메뉴바 우측에 Toki Monitor 아이콘이 나타남
- toki 데몬이 실행 중이면 연결됨 상태
- Claude Code 등 AI 도구를 사용하면 애니메이션 반응

## Development

### 프로젝트 구조

```
TokiMonitor/
├── Data/           # toki UDS 통신
├── Domain/         # 비즈니스 로직
├── Presentation/   # SwiftUI 뷰
├── Resources/      # 에셋
└── Tests/          # 테스트
```

### 테스트 실행

```bash
# Xcode에서
Cmd+U

# CLI에서
xcodebuild test -scheme TokiMonitor -destination 'platform=macOS'
```

### toki 없이 개발

toki 데몬 없이도 앱은 실행됨 (disconnected 상태).
UDS mock 서버로 테스트 가능:

```bash
# 간단한 mock (socat 사용)
echo '{"type":"event","data":{"model":"claude-opus-4-6","source":"test1234","input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cost_usd":0.01}}' | socat - UNIX-CONNECT:~/.config/toki/daemon.sock
```

## Distribution (Homebrew)

### 로컬 빌드

```bash
# Archive
xcodebuild archive -scheme TokiMonitor -archivePath build/TokiMonitor.xcarchive

# Export
xcodebuild -exportArchive -archivePath build/TokiMonitor.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/

# ZIP
cd build && zip -r TokiMonitor.zip TokiMonitor.app
```

### Homebrew Tap (초기 배포)

```bash
brew tap <user>/toki-monitor
brew install --cask toki-monitor
```
