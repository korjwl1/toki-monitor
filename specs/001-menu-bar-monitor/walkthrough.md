# Implementation Walkthrough

**Generated**: 2026-03-17
**Task**: WP03 - Provider Summary Popover

## Summary

메뉴바 클릭 시 프로바이더별(Claude/Gemini/OpenAI) 토큰 사용량과 추정 비용을
표시하는 팝오버를 구현했습니다. ProviderRegistry가 모델명 접두사로 프로바이더를
데이터 기반으로 매핑하고, TokenAggregator에 시간 범위(30m/1h/today) 필터링과
프로바이더 그룹핑을 추가했습니다.

## Files Modified

| Status | File |
|--------|------|
| A | TokiMonitor/Domain/TokenUsageModel.swift |
| A | TokiMonitor/Domain/ProviderRegistry.swift |
| A | TokiMonitor/Domain/ProviderSummary.swift |
| A | TokiMonitor/Data/TokiReportClient.swift |
| A | TokiMonitor/Presentation/Popover/PopoverContentView.swift |
| A | TokiMonitor/Presentation/Popover/ProviderRowView.swift |
| A | TokiMonitor/Presentation/Popover/TotalSummaryView.swift |
| M | TokiMonitor/Domain/TokenAggregator.swift |
| M | TokiMonitor/Presentation/MenuBar/StatusBarController.swift |
| A | Tests/TokiMonitorTests/Domain/ProviderRegistryTests.swift |

## Key Changes

- **ProviderRegistry**: 모델 접두사 → 프로바이더 매핑 (claude-→Anthropic, gemini-→Google, gpt-/o1-/o3-→OpenAI). 대소문자 무관.
- **PopoverContentView**: 헤더(rate + 연결 상태) + 프로바이더 행 + 합산 행 + 푸터(시간 범위 picker, 대시보드/설정 버튼).
- **ProviderRowView**: 아이콘, 이름, in/out 토큰, 비용. 가격 없으면 "--" 표시.
- **TotalSummaryView**: 2개+ 프로바이더일 때 상단 합산 행.
- **TokenAggregator**: TimeRange enum 추가, providerSummaries/totalSummary 계산.

## Commits

- `09ff8d7` [WP03] Implement provider summary popover with time range

## Next Steps

1. Review → Accept → WP03 done
2. WP04 (Dashboard) or WP05 (Settings & Polish)
