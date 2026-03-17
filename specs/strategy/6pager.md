# 6-Pager: Toki Monitor

## 1. 한 줄 요약

AI 코딩 도구(Claude Code, Gemini CLI 등)를 사용하는 macOS 개발자를 위한 메뉴바 토큰 사용량 모니터로, toki 엔진을 기반으로 실시간 토큰 소모율과 누적 비용을 한눈에 보여준다.

## 2. 배경과 목적

### 왜 지금인가

- **AI 코딩 도구 폭발적 성장**: GitHub Copilot 2,000만 사용자, OpenAI API 개발자 210만+, Claude 월간 사용자 1,890만. 개발자 89%가 AI 도구를 사용 중 (2025)
- **비용 가시성 부재**: Claude Code는 토큰 사용 데이터를 `~/.claude/` JSONL 파일에 묻어두며, 개발자에게 직접적인 비용 대시보드를 제공하지 않음
- **비용 사고 빈발**: API 키 도용($82K), 프롬프트 실수($8K/11일), 예기치 않은 스파이크($67/2일) 등 비용 관련 사고가 계속 보고됨
- **기존 솔루션 격차**: Helicone/Langfuse 등 LLM 관측 플랫폼은 서버사이드 웹 대시보드로 팀/기업 대상. macOS 메뉴바 수준의 개인 개발자용 실시간 모니터는 사실상 부재

### 해결하려는 문제

개발자가 AI 도구를 사용하면서 **지금 이 순간 얼마나 토큰을 쓰고 있는지, 그것이 얼마인지** 알 수 없다. 이로 인해:
- 쿼터를 예측 불가하게 소진하여 작업 중단
- 월말 청구서를 보고서야 과다 사용을 인지
- 어떤 세션/모델이 비용을 유발하는지 파악 불가

### toki 엔진의 존재

이미 `toki`(clitrace)라는 Rust 기반 토큰 추적 데몬이 개발되어 있다:
- Claude Code JSONL 로그 실시간 파싱
- fjall TSDB에 이벤트 저장 (13ms 보고 지연)
- UDS(Unix Domain Socket) 기반 실시간 이벤트 스트리밍
- LiteLLM 가격 데이터 연동 비용 계산
- `LogParser` 트레이트로 프로바이더 확장 가능 (Gemini 분석 완료)

**Toki Monitor는 이 엔진 위에 macOS 네이티브 프레젠테이션 레이어를 구축하는 프로젝트다.**

## 3. 목표 & KPI

### 비전

macOS 개발자의 AI 도구 사용에 대한 **비용 의식(cost consciousness)**을 일상 워크플로에 자연스럽게 녹여내는 것. 메뉴바에서 한 눈에, 클릭 한 번에 상세하게.

### 핵심 KPI

| KPI | 목표 | 측정 방법 |
|-----|------|-----------|
| GitHub Stars | 1,000+ (6개월) | GitHub API |
| Homebrew 설치 수 | 500+ (6개월) | brew analytics (opt-in) |
| 유지 아이들 CPU | <1% | Instruments 프로파일링 |
| 메모리 사용량 | <50 MB | Activity Monitor |
| toki 이벤트 → UI 반영 지연 | <500ms | 내부 측정 |

### 비-목표 (Non-goals)

- 수익 창출 (무료 오픈소스)
- 팀/기업 기능 (멀티유저, 권한 관리)
- 서버사이드 데이터 수집
- Windows/Linux 지원

## 4. 시장 크기

### TAM (Total Addressable Market)

**AI API 시장**: $44.4B (2025) → $179B (2030), CAGR 32.2%
- 모든 AI API를 사용하는 개발자/팀이 비용 가시성을 필요로 함

### SAM (Serviceable Available Market)

**AI 코딩 도구 시장**: $6.04B (2024) → $37.34B (2032), CAGR 25.62%
- macOS에서 AI 코딩 도구를 사용하는 개발자 (Copilot 2,000만 중 macOS 비율 ~30% = 600만)

### SOM (Serviceable Obtainable Market)

**개인 개발자 세그먼트**: Claude Code + Gemini CLI를 macOS에서 사용하는 개인 개발자
- 초기 타겟: toki 기반 Claude Code 사용자 (수만~수십만 추정)
- 무료 오픈소스이므로 금전적 SOM보다 **설치 수**가 핵심 지표

| 출처 | 데이터 | 신뢰도 |
|------|--------|--------|
| SNS Insider | AI 코드 도구 시장 $6.04B (2024) | 🟡 참고 |
| MarketsandMarkets | AI API 시장 $44.4B (2025) | 🟡 참고 |
| TechCrunch | Copilot 2,000만 사용자 (2025.07) | 🟢 검증됨 |
| ElectroIQ | OpenAI API 개발자 210만+ | 🟡 참고 |

## 5. 고객 이해

### 페르소나: "토큰 감시자" 민수 (30대 백엔드 개발자)

- **역할**: 스타트업 시니어 개발자, Claude Code Max 구독자
- **일상**: 하루 8시간+ Claude Code와 페어 프로그래밍
- **Pain Point**: 작업 중 갑자기 쿼터 소진되어 세션 중단. 어제 리팩토링에 토큰을 얼마나 썼는지 모름
- **현재 워크아라운드**: 가끔 Anthropic 콘솔에 들어가 보지만 실시간이 아님
- **원하는 것**: "지금 토큰이 얼마나 빨리 빠지고 있는지 상단바에서 바로 보고 싶다"

### Jobs To Be Done

| Job | 유형 | 현재 대안 |
|-----|------|-----------|
| 실시간 토큰 소모 속도를 파악하고 싶다 | 기능적 | 없음 (JSONL 직접 파싱) |
| 오늘/이번 주 비용을 빠르게 확인하고 싶다 | 기능적 | Anthropic 콘솔 (수동, 지연) |
| AI 도구 비용을 통제하고 있다는 안심감 | 감정적 | 없음 |
| 어떤 모델/세션이 비용을 유발하는지 알고 싶다 | 기능적 | 없음 |

## 6. 경쟁사 비교

### 직접 경쟁 (macOS 메뉴바 AI 모니터)

| 도구 | Stars | 초점 | 데이터 소스 | 약점 |
|------|-------|------|-------------|------|
| **Claude Usage Tracker** | 1,600 | Claude 구독 쿼터 | 웹 스크래핑/API | Claude 전용, 토큰 비용 미표시 |
| **ClaudeBar** | 801 | 멀티 AI 쿼터 바 | 각 CLI 도구 출력 | 쿼터% 표시, 실시간 토큰 추적 아님 |

### 간접 경쟁 (서버사이드 LLM 관측)

| 도구 | 유형 | 가격 | 약점 (개인 개발자 관점) |
|------|------|------|------------------------|
| **Helicone** | 프록시 기반 | Free 10K req/mo | 서버 설정 필요, 로컬 CLI 도구 미지원 |
| **Langfuse** | 오픈소스 플랫폼 | Free 50K events/mo | 웹 대시보드, 메뉴바 통합 없음 |
| **LiteLLM** | 프록시 | 무료 | 팀 대상, 인프라 설정 필요 |

### UX 레퍼런스 (macOS 시스템 모니터)

| 도구 | Stars/인기 | 가격 | 배울 점 |
|------|-----------|------|---------|
| **Stats** | 37,100 | 무료 | 모듈형 메뉴바 위젯, Homebrew 배포 |
| **RunCat** | App Store 인기 | 무료+IAP | 애니메이션으로 수치를 직관적 표현 |
| **iStat Menus** | 장기 인기 | $11.99 | 상세 커스터마이즈, 알림 설정 |

### Toki Monitor 포지셔닝

```
              쿼터 추적           토큰/비용 추적
메뉴바 앱     ClaudeBar           ★ Toki Monitor ★
              Claude Tracker
웹 대시보드   Anthropic Console   Helicone, Langfuse
```

**핵심 차별점**: 유일하게 **실시간 토큰 단위 비용**을 **macOS 메뉴바**에서 보여주는 도구. toki의 TSDB 기반으로 과거 데이터 분석까지 제공.

## 7. 해결책 & USP

### 핵심 기능

| 기능 | 설명 | 가치 |
|------|------|------|
| **메뉴바 애니메이션** | 토큰 소모율에 따라 속도/강도가 변하는 아이콘 | 코딩 중 시선 이동 없이 현재 상태 파악 |
| **팝오버 요약** | 클릭 시 프로바이더별 최근 사용량/비용 표시 | 10초 안에 오늘 사용 현황 파악 |
| **대시보드 앱** | 기간별 세부 데이터, 세션별 분석, 모델별 비교 | 비용 최적화를 위한 심층 분석 |
| **toki 데몬 연동** | UDS 실시간 이벤트 + TSDB 이력 쿼리 | 0% 추가 오버헤드, 검증된 데이터 파이프라인 |
| **멀티 프로바이더** | toki LogParser로 Claude, Gemini 등 확장 | 단일 뷰에서 전체 AI 비용 관리 |

### USP (Unique Selling Proposition)

> **"AI 비용을 보이게 만든다"** — 개발 흐름을 끊지 않으면서 실시간 토큰 비용을 시각화하는 유일한 macOS 네이티브 도구

경쟁사와의 차별점:
1. **실시간 토큰 비용** (쿼터%가 아닌 달러/토큰 단위)
2. **toki TSDB 기반 이력 분석** (13ms 쿼리, 무한 보존)
3. **제로 설정** (toki 데몬만 실행하면 자동 연동)
4. **확장 가능 아키텍처** (프로바이더 추가 시 UI 변경 불필요)

### MVP 범위

1. toki UDS 연결 → 실시간 이벤트 수신
2. 메뉴바 아이콘 + 토큰 속도 기반 애니메이션
3. 팝오버: Claude 프로바이더 사용량/비용 요약
4. 기본 설정 (애니메이션 스타일, 시간 범위)

## 8. User Stories

### US-1: 실시간 토큰 모니터링 (P1 - MVP)

> 개발자로서, 메뉴바에서 현재 AI 토큰 소모 속도를 한눈에 보고 싶다.

**수용 조건**:
- Given toki 데몬이 실행 중일 때, When AI 도구가 토큰을 소비하면, Then 메뉴바 아이콘 애니메이션 속도가 소모율에 비례하여 변함
- Given 토큰 이벤트가 없을 때, Then 아이콘이 정지 상태로 표시됨

### US-2: 프로바이더별 사용량 요약 (P1 - MVP)

> 개발자로서, 메뉴바를 클릭하면 프로바이더별 최근 사용량과 비용을 보고 싶다.

**수용 조건**:
- Given 메뉴바 아이콘 클릭 시, Then 팝오버에 각 프로바이더(Claude, Gemini 등)의 최근 1시간 토큰 사용량과 추정 비용이 표시됨
- Given 가격 데이터가 없는 프로바이더의 경우, Then 토큰 수만 표시됨

### US-3: 상세 대시보드 (P2)

> 개발자로서, 기간별 세부 사용 데이터를 분석하고 싶다.

**수용 조건**:
- Given 팝오버에서 "대시보드" 클릭 시, Then 별도 윈도우에서 일간/주간/월간 리포트가 표시됨
- Given 대시보드에서 기간 선택 시, Then 모델별, 세션별 사용량 분석이 표시됨

### US-4: 데몬 연결 관리 (P1 - MVP)

> 개발자로서, toki 데몬이 꺼져있을 때 이를 알 수 있고 쉽게 시작할 수 있어야 한다.

**수용 조건**:
- Given toki 데몬 미실행 시, Then 메뉴바에 "연결 끊김" 상태 아이콘 표시
- Given "연결 끊김" 상태에서 클릭 시, Then 원클릭 데몬 시작 옵션 제공

## 9. 비즈니스 모델

### 수익 모델: 없음 (오픈소스)

- **라이선스**: MIT 예정
- **수익화 계획**: 없음 — 개인 프로젝트 + 커뮤니티 기여
- **비용 구조**: 개발자 시간 외 추가 비용 없음 (서버 없음, 인프라 없음)

### 가치 창출 경로

개인 오픈소스 프로젝트로서의 가치:
1. **toki 생태계 확장**: toki 라이브러리의 시각적 프론트엔드로서 가치 입증
2. **포트폴리오**: macOS 네이티브 앱 + Rust 연동 + 실시간 데이터 처리 역량 시연
3. **커뮤니티**: AI 개발자 커뮤니티 내 인지도 구축

## 10. GTM (Go-to-Market) 전략

### 런칭 전략

| 단계 | 활동 | 채널 |
|------|------|------|
| 0. 개발 | toki 기반 MVP 개발 | — |
| 1. 소프트 런칭 | GitHub 공개 + Homebrew tap | GitHub |
| 2. 커뮤니티 공유 | Reddit, Hacker News, X/Twitter 포스팅 | r/ClaudeAI, r/MacApps, HN Show |
| 3. Homebrew 공식 | homebrew-cask PR 제출 | Homebrew |

### 초기 사용자 확보

- **r/ClaudeAI, r/LocalLLaMA**: Claude Code 사용자 밀집
- **Hacker News Show HN**: 개발자 도구 노출 최적
- **X/Twitter**: #ClaudeCode, #AIDevTools 해시태그
- **toki GitHub README**: 크로스 프로모션

## 11. 제품 원칙

1. **보이지 않는 존재감**: 필요할 때만 눈에 띄고, 평소에는 시스템 자원을 소모하지 않는다
2. **숫자로 말한다**: "많이 썼다"가 아닌 "$2.47, 15,230 tokens"로 보여준다
3. **toki에 의존한다**: 데이터 수집/저장을 재발명하지 않는다
4. **확장은 toki에서**: 새 프로바이더 지원은 UI가 아닌 toki 파서 추가로 해결한다
5. **macOS 시민이다**: 플랫폼 가이드라인을 따르고, 네이티브 UX를 제공한다

## 12. 마일스톤

| 마일스톤 | 내용 | 기한 |
|----------|------|------|
| **M1: Foundation** | Xcode 프로젝트 셋업, toki UDS 클라이언트, 기본 메뉴바 아이콘 | 기한 없음 |
| **M2: Live Monitor** | 실시간 이벤트 수신, 애니메이션 메뉴바, 기본 팝오버 | 기한 없음 |
| **M3: Provider Summary** | 프로바이더별 사용량/비용, 시간 범위 선택, 설정 | 기한 없음 |
| **M4: Dashboard** | 대시보드 윈도우, toki report 연동, 차트 | 기한 없음 |
| **M5: Distribution** | Homebrew 배포, 코드 사이닝, 노터라이제이션 | 기한 없음 |

## 13. 리스크

| 리스크 | 영향 | 확률 | 대응 |
|--------|------|------|------|
| **toki API 변경** | 높음 | 낮음 | toki가 동일 개발자 소유, 인터페이스 안정화 가능 |
| **경쟁자 빠른 진화** | 중간 | 중간 | ClaudeBar/Tracker가 비용 추적 추가 가능 → 차별화로 TSDB 기반 이력 분석 강조 |
| **macOS API 변경** | 중간 | 낮음 | SwiftUI/AppKit은 안정적, 연간 1회 점검 |
| **Gemini 등 파서 미완성** | 중간 | 높음 | MVP는 Claude 전용으로 출시, 프로바이더 확장은 점진적 |
| **사용자 관심 부족** | 중간 | 중간 | Show HN + Reddit 피드백 기반 방향 조정 |

## 14. 오픈 이슈

| # | 이슈 | 상태 | 결정 필요 시점 |
|---|------|------|---------------|
| 1 | 메뉴바 애니메이션 스타일 결정 (RunCat 캐릭터형 vs Stats 그래프형 vs 커스텀) | [TBD] | M2 개발 시 |
| 2 | toki 연동 방식: UDS 직접 연결 vs CLI 래핑 vs Swift에서 Rust FFI | [TBD] | M1 리서치 |
| 3 | 대시보드 차트 라이브러리 선정 (Swift Charts vs 커스텀) | [TBD] | M4 개발 시 |
| 4 | 코드 사이닝: 개인 Apple Developer 계정 필요 여부 | [TBD] | M5 |
| 5 | 최소 지원 macOS 버전 (Sonoma 14+ vs Ventura 13+) | [TBD] | M1 |

---

**출처 테이블**

| 데이터 | 값 | 출처 | 신뢰도 |
|--------|-----|------|--------|
| AI 코드 도구 시장 | $6.04B (2024) | SNS Insider via Yahoo Finance | 🟡 참고 |
| AI API 시장 | $44.4B (2025) | MarketsandMarkets | 🟡 참고 |
| GitHub Copilot 사용자 | 20M (2025.07) | TechCrunch | 🟢 검증됨 |
| OpenAI API 개발자 | 2.1M+ | ElectroIQ | 🟡 참고 |
| Claude MAU | 18.9M | Business of Apps | 🟡 참고 |
| 개발자 AI 도구 채택률 | 89% | Keyhole Software | 🟡 참고 |
| LLM 예산 비효율 | 40-60% 낭비 | LeanTechPro | 🟡 참고 |
| Gemini API 키 사고 | $82,314 | Techzine | 🟢 검증됨 |
| Claude Code 일일 비용 | 평균 $6, 상위 10% $12+ | AI Engineering Report | 🟡 참고 |
| Stats GitHub Stars | 37,100 | GitHub | 🟢 검증됨 |
| ClaudeBar GitHub Stars | 801 | GitHub | 🟢 검증됨 |
| Claude Usage Tracker Stars | 1,600 | GitHub | 🟢 검증됨 |
