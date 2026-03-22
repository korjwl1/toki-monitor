# Toki Monitor — 강점과 포지셔닝

**프록시 없이 동작하는 실시간 메뉴바 AI 토큰 모니터. toki의 Rust TSDB 엔진 기반.**

Toki Monitor는 [toki](https://github.com/korjwl1/toki)의 macOS UI 레이어입니다. toki는 Rust 기반 CLI로, AI 토큰 사용량 데이터를 수집하고 로컬 시계열 데이터베이스(fjall)에 저장합니다. `trace` 이벤트는 메뉴바 애니메이션으로, `report` 쿼리는 Grafana 스타일 대시보드로 연결됩니다.

## toki 아키텍처의 우위

직접 파일 폴링 도구(TokenBar, Tokscale, SessionWatcher)와 달리, toki는 **데몬 + TSDB** 아키텍처를 사용합니다:

| | toki (우리) | 직접 폴링 (경쟁사) |
|---|---|---|
| **데이터 수집** | Rust 데몬, kqueue/FSEvents 이벤트 기반 — idle 시 CPU 0% | 주기적 파일 스캔 — 데이터 양에 비례하여 CPU 소모 |
| **저장** | fjall TSDB (~2.2 MB 바이너리) — 인덱싱, 쿼리 가능 | 없음 또는 메모리 — 앱 종료 시 소실 |
| **쿼리** | PromQL 스타일 즉시 응답 | 매번 전체 재스캔 |
| **메모리** | ~수 MB (Rust, GC 없음) | 30-50 MB+ (Node.js) 또는 데이터에 비례 |
| **장기 데이터** | O(변경분) 증분 업데이트 | O(전체 데이터) 풀 스캔, 시간 경과 시 성능 저하 |
| **멀티 클라이언트** | CLI + 메뉴바 앱이 동일 데몬 공유 | 각 도구가 독립적으로 스캔 |

## 프록시 불필요

프록시 기반 모니터(BurnRate)와 달리:
- **네트워크 가로채기 없음, TLS 인터셉션 없음, 도구 재설정 불필요.** 기존 CLI 도구를 그대로 사용합니다.
- **정규화된 스키마 기반.** 모델, 토큰 분류, 비용 데이터가 구조화되어 일관성이 높습니다.

## 제품 강점

### 항상 보이는 실시간 피드백
- RunCat 스타일 토끼 애니메이션 — 토큰 속도에 비례
- idle 시 수면 애니메이션 (zZ), 대기 시간 설정 가능
- 3가지 표시 모드: 캐릭터 애니메이션, 수치, 스파크라인 그래프
- 프로바이더별 또는 합산 상태바 아이템

### Grafana 스타일 대시보드
- 드래그 드롭 패널 레이아웃 커스텀
- 타임시리즈, 바 차트, 스탯, 게이지, 테이블 패널
- toki CLI 기반 PromQL 쿼리
- 변수 시스템, 절대 시간 범위 선택
- 대시보드 버전 관리 및 어노테이션

### 이상 감지
- **비용 속도 경고**: 분당 비용 임계값 초과 시 아이콘 색상 변경
- **과거 기준 분석**: PromQL로 24시간 평균 대비 비교
- 경고 방식 선택: 아이콘 색상, 시스템 알림, 또는 둘 다
- 경고 색상 사용자 지정

### Claude 연동
- OAuth 기반 사용량/레이트 리밋 모니터링
- 5시간/7일 사용량 바 + 리셋 카운트다운
- 사용량 임계값 알림 (75%, 90%)

### Codex 연동
- ~/.codex/auth.json에서 OAuth 토큰 자동 읽기 (추가 로그인 불필요)
- 5시간/주간 사용량 바 + 지역화된 카운트다운
- Codex CLI 로그인 여부 자동 감지

### UX 완성도
- 우클릭 컨텍스트 메뉴 (설정, 종료)
- 위젯 순서 커스텀 (드래그 드롭 + 표시/숨김)
- 대시보드 열면 Dock에 표시, 닫으면 숨김
- 데몬 연결 끊김 시 자동 재연결 (3회 백오프)
- Liquid Glass 디자인 지원 (macOS Tahoe)
- 한국어/영어 완전 지역화

### 개발자 친화적
- 오픈소스, 무료, MIT 라이선스
- Homebrew 배포 (예정)
- Clean Architecture: Data / Domain / Presentation 레이어
- async/await 전환 완료, 통합 디자인 시스템

## 아키텍처

```
toki (Rust 데몬)                Toki Monitor (Swift/SwiftUI)
├─ fjall TSDB                   ├─ Data        // UDS trace, CLI report, OAuth
├─ 파일 감시 (kqueue)           ├─ Domain      // 집계, 알림, 설정
├─ PromQL 엔진                  └─ Presentation// 메뉴바, 대시보드, 설정
└─ UDS 서버

데이터 흐름:
  toki daemon → toki trace → UDS → TokiEventStream → TokenAggregator → 메뉴바
  toki report (PromQL) → TokiReportClient → DashboardViewModel → 차트
```

## 경쟁 환경 (2026년 3월)

현재 macOS 메뉴바 앱만 9개 이상. Toki Monitor만의 고유 우위로 **경쟁사 중 단 하나도 제공하지 않는** 기능들:

1. **TSDB 기반 히스토리 분석** — 어떤 시간 범위든 즉시 쿼리
2. **PromQL 쿼리 언어** — 메뉴바 앱 중 유일
3. **Grafana 스타일 커스텀 대시보드** — 메뉴바 앱 중 유일
4. **토큰 속도 연동 애니메이션 아이콘** — 시각적 실시간 피드백
5. **오픈소스 + 무료** — 유료 앱($2-5) 수준의 기능 깊이

## 가장 적합한 사용자

- AI 도구로 코딩하면서 **즉시 시각적 피드백**이 필요한 개발자
- 프록시 없이 **정확한 비용 추적**을 원하는 사용자
- **히스토리 + 대시보드 + 분석**을 로컬에서 처리하고 싶은 사용자

**한 줄 포지셔닝:** 프록시 없이, Rust TSDB/PromQL 엔진을 등에 업은 가벼운 로컬 메뉴바 UX.
