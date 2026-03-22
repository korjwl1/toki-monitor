# Toki Monitor 경쟁 환경 분석 (2026년 3월)

## 시장 변화

6-pager 작성 시점 직접 경쟁자 2개 → 현재 macOS 메뉴바 앱만 **9개 이상**으로 급증.
AI 코딩 도구 폭발적 성장과 함께 토큰/비용 모니터링 수요가 빠르게 형성되고 있음.

---

## Toki Monitor 고유 우위

아래 기능은 조사된 경쟁자 중 **단 하나도 제공하지 않는** 기능들:

| 기능 | 설명 |
|------|------|
| TSDB 기반 히스토리 | fjall 시계열 DB — 장기 사용량 추적 및 분석 |
| PromQL 쿼리 언어 | toki CLI를 통한 자유 쿼리 |
| Grafana 스타일 대시보드 | 패널 커스텀, 드래그 드롭, 변수 시스템 |
| RunCat 스타일 애니메이션 | 토큰 속도에 비례하는 토끼 달리기 + 수면 모션 |
| 오픈소스 + 무료 + 기능 깊이 | 유료 앱 수준의 기능을 무료 오픈소스로 제공 |

---

## Tier 1: 직접 경쟁자 (macOS 메뉴바, 토큰/비용 추적)

### TokenBar
- **사이트**: https://www.tokenbar.site
- **가격**: $4.99 (일회성)
- **프로바이더**: 20+ (Codex, Claude, Cursor, Gemini, Copilot, OpenRouter, Vertex AI, Augment, Amp, JetBrains AI, Ollama, Warp, Kimi, Kiro 등)
- **주요 기능**: 프롬프트 루프/재시도/폴백 감지, 리셋 윈도우 대비 적자/잉여 페이싱, 이상 알림, 로컬 처리
- **Toki 대비 강점**: 가장 넓은 프로바이더 커버리지, 루프 감지, 페이싱 분석
- **Toki 대비 약점**: TSDB 없음, PromQL 없음, 대시보드 없음, 애니메이션 없음, 비오픈소스

### BurnRate
- **사이트**: https://getburnrate.app
- **가격**: 유료 (추정)
- **방식**: 로컬 프록시가 모든 AI 도구의 토큰 사용량 가로채기
- **Toki 대비 강점**: 프록시 기반 — 로그 형식 무관하게 모든 도구 캡처 가능
- **Toki 대비 약점**: 네트워크 홉 추가, 대시보드/차트 없음, TSDB 없음, 비오픈소스

### SessionWatcher
- **사이트**: https://www.sessionwatcher.com
- **가격**: $1.99 (일회성)
- **프로바이더**: Claude Code, Codex
- **주요 기능**: 제로 설정 (API 키/터미널 불필요), 리셋 윈도우 카운트다운, 로컬 처리
- **Toki 대비 강점**: 설치만 하면 끝 (제로 설정), 리셋 카운트다운
- **Toki 대비 약점**: 프로바이더 2개, 히스토리/대시보드 없음, 비오픈소스

### Agent Monitor
- **사이트**: https://agentmonitor.dev
- **가격**: 무료
- **프로바이더**: Claude, Cursor, GPT 등
- **Toki 대비 강점**: 무료이며 이미 배포 중, 멀티 프로바이더
- **Toki 대비 약점**: TSDB 없음, 대시보드 없음, 기능 깊이 부족

---

## Tier 2: 직접 경쟁자 (macOS 메뉴바, 쿼터/사용량 추적 — 비용 아님)

### Claude Usage Tracker
- **GitHub**: https://github.com/hamed-elfayome/Claude-Usage-Tracker (⭐ ~1,600)
- **가격**: 무료, 오픈소스
- **주요 기능**: 5시간 세션 윈도우, 주간 한도, Opus 쿼터 추적, **멀티 계정 프로필**
- **Toki 대비 강점**: 멀티 계정 전환, 높은 인지도 (GitHub 스타)
- **Toki 대비 약점**: Claude 전용, 쿼터 %만 (토큰/비용 없음), 히스토리/대시보드 없음

### ClaudeBar
- **GitHub**: https://github.com/tddworks/ClaudeBar (⭐ ~801)
- **가격**: 무료, 오픈소스
- **프로바이더**: Claude, Codex, Gemini, GitHub Copilot, Antigravity, Z.ai, Kimi, Kiro, Amp
- **주요 기능**: 색상별 진행 바, 시스템 알림, 테마 시스템, **Homebrew 배포 중**
- **Toki 대비 강점**: 이미 `brew install --cask claudebar`, 넓은 쿼터 지원, 테마
- **Toki 대비 약점**: 쿼터 %만, 실시간 스트리밍 없음, TSDB/대시보드 없음

### Usage4Claude
- **GitHub**: https://github.com/f-is-h/Usage4Claude
- **주요 기능**: 모든 Claude 플랫폼 (Web, Code, Desktop, Mobile, Cowork), 5개 한도 동시 표시
- **Toki 대비 약점**: Claude 전용, 비용 추적 없음

### ClaudeMeter / ClaudeUsageBar
- 경량 Claude 쿼터 표시 앱들. 기능 최소.

---

## Tier 3: CLI 도구

### Tokscale
- **GitHub**: https://github.com/junhoyeo/tokscale
- **가격**: 무료, 오픈소스
- **프로바이더**: 15+ (OpenCode, Claude Code, Codex, Cursor, Gemini, Amp, Kimi, Qwen 등)
- **주요 기능**: CLI + 터미널 UI, LiteLLM 기반 실시간 가격, 기여 그래프, **글로벌 리더보드**
- **Toki 대비 강점**: 가장 많은 프로바이더, 소셜/게이미피케이션 (리더보드), 크로스플랫폼
- **Toki 대비 약점**: CLI 전용 (메뉴바 없음), 네이티브 UI 없음

---

## Tier 4: 간접 경쟁자 (서버사이드/엔터프라이즈)

| 서비스 | 특징 | Toki와의 차이 |
|--------|------|-------------|
| **Helicone** | 프록시 기반 LLM 옵저빌리티, 20억+ 요청 처리 | 웹 대시보드, 팀/엔터프라이즈용 |
| **Langfuse** (⭐ 23,000+) | 전체 LLM 엔지니어링 플랫폼, 프롬프트 관리 | SDK 통합 필요, 개인 개발자 워크플로우 아님 |
| **CostLayer** | 실시간 AI 지출 가시화 | 웹, 팀 중심 |
| **AI Cost Bar** ($2.99) | LLM 가격 **계산기** (모니터 아님) | 보완재, 경쟁자 아님 |

---

## 포지셔닝 매트릭스

```
                    쿼터/한도 추적              토큰/비용 추적
                    ──────────────          ─────────────────
macOS 메뉴바        Claude Usage Tracker    TokenBar ($4.99)
(네이티브)          ClaudeBar               BurnRate
                    Usage4Claude            SessionWatcher ($1.99)
                    ClaudeMeter             Agent Monitor (무료)
                    ClaudeUsageBar          ★ TOKI MONITOR ★

CLI / 터미널        —                       Tokscale

웹 대시보드         프로바이더 콘솔          Helicone
(서버사이드)                                Langfuse
                                            CostLayer
```

---

## Toki Monitor 부족한 점

| 영역 | 현재 상태 | 경쟁자 참고 |
|------|----------|-----------|
| 프로바이더 수 | Anthropic + OpenAI (2개) | TokenBar 20+, Tokscale 15+ |
| Homebrew 배포 | 미배포 | ClaudeBar 배포 중 |
| 제로 설정 | toki CLI 설치 필요 | SessionWatcher 설치만 하면 끝 |
| 리셋 윈도우 페이싱 | 없음 | TokenBar, SessionWatcher |
| 프롬프트 루프/이상 감지 | 없음 | TokenBar |
| 멀티 계정 | 없음 | Claude Usage Tracker |

---

## 개선 우선순위 제안

### 단기
- 프로바이더 추가 (Cursor, Gemini, Copilot 등 — toki CLI 쪽 작업)
- Homebrew cask 배포

### 중기
- 리셋 윈도우 카운트다운 + 페이싱 분석
- 프롬프트 루프/이상 사용 감지 알림

### 장기
- 제로 설정 모드 (toki CLI 없이 직접 로그 읽기)
- 멀티 계정 프로필

---

*조사일: 2026-03-22*
*출처: GitHub, 각 서비스 공식 사이트, Indie Hackers, DEV Community*
