import Foundation

/// Runtime-switchable localization system.
/// Usage: L.settings.general, L.menu.dashboard, etc.
@MainActor
enum L {
    nonisolated(unsafe) static var settings: AppSettings?

    nonisolated static var code: String {
        MainActor.assumeIsolated {
            settings?.language.resolvedCode ?? "ko"
        }
    }

    nonisolated static func tr(_ ko: String, _ en: String) -> String {
        code == "ko" ? ko : en
    }

    // MARK: - Settings Categories

    enum cat {
        static var general: String { tr("일반", "General") }
        static var menuBar: String { tr("메뉴바", "Menu Bar") }
        static var providers: String { tr("프로바이더", "Providers") }
        static var notifications: String { tr("알림", "Notifications") }
    }

    // MARK: - General Settings

    enum general {
        static var language: String { tr("언어", "Language") }
        static var startup: String { tr("시작", "Startup") }
        static var launchAtLogin: String { tr("로그인 시 자동 시작", "Launch at Login") }
    }

    // MARK: - Menu Bar Settings

    enum menuBar {
        static var animation: String { tr("애니메이션", "Animation") }
        static var style: String { tr("스타일", "Style") }
        static var character: String { tr("캐릭터", "Character") }
        static var numeric: String { tr("수치", "Numeric") }
        static var graph: String { tr("그래프", "Graph") }
        static var showRateText: String { tr("캐릭터 옆 토큰 수치 표시", "Show token rate next to character") }
        static var textPosition: String { tr("텍스트 위치", "Text Position") }
        static var unit: String { tr("단위", "Unit") }
        static var sparklineTimeRange: String { tr("스파크라인 시간폭", "Sparkline Time Range") }
        static var displayMode: String { tr("표시 모드", "Display Mode") }
        static var mode: String { tr("모드", "Mode") }
        static var iconColor: String { tr("아이콘 색상", "Icon Color") }
        static var defaultWhite: String { tr("기본 (흰색)", "Default (White)") }
    }

    // MARK: - Provider Settings

    enum provider {
        static var enabled: String { tr("활성화", "Enabled") }
        static var color: String { tr("색상", "Color") }
        static func defaultColor(_ name: String) -> String { tr("기본 (\(name))", "Default (\(name))") }
        static var noProviders: String { tr("활성화된 프로바이더가 없습니다", "No providers enabled") }
    }

    // MARK: - Account

    enum account {
        static var login: String { tr("Claude 로그인", "Claude Login") }
        static var loggingIn: String { tr("인증 대기 중...", "Authenticating...") }
        static var loggedIn: String { tr("로그인됨", "Logged in") }
        static var logout: String { tr("로그아웃", "Logout") }
        static var authFailed: String { tr("인증 실패", "Authentication failed") }
        static var retry: String { tr("다시 시도", "Retry") }
        static var oauthUnavailable: String { tr("OAuth 매니저를 사용할 수 없습니다", "OAuth manager unavailable") }
    }

    // MARK: - Notifications

    enum notification {
        static var claudeUsageAlerts: String { tr("Claude 사용량 알림", "Claude Usage Alerts") }
        static var alert75: String { tr("75% 도달 시 알림", "Alert at 75%") }
        static var alert90: String { tr("90% 도달 시 알림", "Alert at 90%") }
    }

    // MARK: - Menu Panel

    enum panel {
        static var dashboard: String { tr("대시보드", "Dashboard") }
        static var settings: String { tr("설정", "Settings") }
        static func sessions(_ n: Int) -> String { tr("\(n) 세션", "\(n) sessions") }
        static var claudeUsage: String { tr("Claude 사용량", "Claude Usage") }
        static var fiveHour: String { tr("5시간", "5h") }
        static var sevenDay: String { tr("7일", "7d") }
        static var disconnected: String { tr("toki 미연결", "toki disconnected") }
        static var startDaemon: String { tr("데몬 시작", "Start Daemon") }
    }

    // MARK: - Dashboard

    enum dash {
        static var title: String { tr("대시보드", "Dashboard") }
        static var period: String { tr("기간", "Period") }
        static var selectAll: String { tr("전체 선택", "Select All") }
        static var deselectAll: String { tr("전체 해제", "Deselect All") }
        static var filter: String { tr("필터", "Filter") }
        static var refresh: String { tr("새로고침", "Refresh") }
        static var totalTokens: String { tr("총 토큰", "Total Tokens") }
        static var totalCost: String { tr("총 비용", "Total Cost") }
        static var apiCalls: String { tr("API 호출", "API Calls") }
        static var topModel: String { tr("최다 모델", "Top Model") }
        static var tokenTrend: String { tr("토큰 사용량 추이", "Token Usage Trend") }
        static var costTrend: String { tr("비용 추이", "Cost Trend") }
        static var apiTrend: String { tr("API 호출 추이", "API Call Trend") }
        static var selectModel: String { tr("모델을 선택하세요", "Select a model") }
        static var selectModelDesc: String { tr("필터에서 모델을 선택하면 데이터가 표시됩니다", "Select a model from the filter to display data") }
        static var error: String { tr("오류 발생", "Error") }
        static var loading: String { tr("데이터를 불러오는 중...", "Loading data...") }
        // Dashboard editing
        static var edit: String { tr("편집", "Edit") }
        static var addPanel: String { tr("패널 추가", "Add Panel") }
        static var removePanel: String { tr("패널 삭제", "Remove Panel") }
        static var resetLayout: String { tr("레이아웃 초기화", "Reset Layout") }
        static var done: String { tr("완료", "Done") }
        static var pickPanelType: String { tr("패널 종류 선택", "Pick Panel Type") }
        static var pickMetric: String { tr("지표 선택", "Pick Metric") }
        static var cancel: String { tr("취소", "Cancel") }
        static var add: String { tr("추가", "Add") }
        static var modelBreakdown: String { tr("모델 상세", "Model Breakdown") }
        static var cacheHitRate: String { tr("캐시 적중률", "Cache Hit Rate") }
        static var reasoningTokens: String { tr("추론 토큰", "Reasoning Tokens") }
        // Panel type names
        static var statPanel: String { tr("통계", "Stat") }
        static var timeSeriesPanel: String { tr("시계열", "Time Series") }
        static var barChartPanel: String { tr("막대 차트", "Bar Chart") }
        static var tablePanel: String { tr("테이블", "Table") }
        static var gaugePanel: String { tr("게이지", "Gauge") }
        // Metric names
        static var metricTotalTokens: String { tr("총 토큰", "Total Tokens") }
        static var metricTotalCost: String { tr("총 비용", "Total Cost") }
        static var metricApiCalls: String { tr("API 호출", "API Calls") }
        static var metricTopModel: String { tr("최다 모델", "Top Model") }
        static var metricTokensByModel: String { tr("모델별 토큰", "Tokens by Model") }
        static var metricCostByModel: String { tr("모델별 비용", "Cost by Model") }
        static var metricEventsByModel: String { tr("모델별 호출", "Events by Model") }
        static var metricInputVsOutput: String { tr("입력 vs 출력", "Input vs Output") }
        static var metricCacheHitRate: String { tr("캐시 적중률", "Cache Hit Rate") }
        static var metricReasoningTokens: String { tr("추론 토큰", "Reasoning Tokens") }
        static var metricModelBreakdown: String { tr("모델 상세", "Model Breakdown") }
        // Chart axis labels
        static var axisTime: String { tr("시간", "Time") }
        static var axisTokens: String { tr("토큰", "Tokens") }
        static var axisCost: String { tr("비용", "Cost") }
        static var axisModel: String { tr("모델", "Model") }
        static var axisCalls: String { tr("호출", "Calls") }
        // Table column headers
        static var inputTokens: String { tr("입력 토큰", "Input Tokens") }
        static var outputTokens: String { tr("출력 토큰", "Output Tokens") }
        // Sidebar & Multi-dashboard
        static var dashboards: String { tr("대시보드 목록", "Dashboards") }
        static var newDashboard: String { tr("새 대시보드", "New Dashboard") }
        static var importDashboard: String { tr("가져오기", "Import") }
        static var search: String { tr("검색", "Search") }
        static var duplicate: String { tr("복제", "Duplicate") }
        static var delete: String { tr("삭제", "Delete") }
        static var confirmDelete: String { tr("정말 삭제하시겠습니까?", "Are you sure you want to delete?") }
        // Dashboard settings
        static var dashboardSettings: String { tr("대시보드 설정", "Dashboard Settings") }
        static var description: String { tr("설명", "Description") }
        static var tags: String { tr("태그", "Tags") }
        static var timezone: String { tr("시간대", "Timezone") }
        static var defaultTimeRange: String { tr("기본 시간 범위", "Default Time Range") }
        static var defaultRefresh: String { tr("기본 새로고침", "Default Refresh") }
        static var variables: String { tr("변수", "Variables") }
        static var jsonModel: String { tr("JSON 모델", "JSON Model") }
        // Row panels
        static var addRow: String { tr("행 추가", "Add Row") }
        static var collapse: String { tr("접기", "Collapse") }
        static var expand: String { tr("펼치기", "Expand") }
        // Annotations
        static var annotations: String { tr("주석", "Annotations") }
        static var addAnnotation: String { tr("주석 추가", "Add Annotation") }
        static var annotationText: String { tr("주석 내용", "Annotation text") }
        // Alerts
        static var alerts: String { tr("알림 규칙", "Alert Rules") }
        static var addAlert: String { tr("알림 추가", "Add Alert") }
        static var alertName: String { tr("알림 이름", "Alert Name") }
        static var condition: String { tr("조건", "Condition") }
        static var threshold: String { tr("임계값", "Threshold") }
        // Explore
        static var explore: String { tr("탐색", "Explore") }
        static var queryHistory: String { tr("쿼리 기록", "Query History") }
        static var runQuery: String { tr("쿼리 실행", "Run Query") }
        // Versioning
        static var versions: String { tr("버전 기록", "Version History") }
        static var restore: String { tr("복원", "Restore") }
        static var compare: String { tr("비교", "Compare") }
        // Playlists
        static var playlists: String { tr("재생목록", "Playlists") }
        static var newPlaylist: String { tr("새 재생목록", "New Playlist") }
        static var interval: String { tr("간격", "Interval") }
        static var play: String { tr("재생", "Play") }
        static var pause: String { tr("일시정지", "Pause") }
        static var stop: String { tr("정지", "Stop") }
        // Data Links
        static var dataLinks: String { tr("데이터 링크", "Data Links") }
        static var addLink: String { tr("링크 추가", "Add Link") }
        static var linkTitle: String { tr("링크 제목", "Link Title") }
        static var linkURL: String { tr("URL", "URL") }
        // Sidebar
        static var sidebar: String { tr("사이드바", "Sidebar") }
        static var toggleSidebar: String { tr("사이드바 토글", "Toggle Sidebar") }
    }

    // MARK: - Enums

    enum enumStr {
        // TextPosition
        static var left: String { tr("왼쪽", "Left") }
        static var right: String { tr("오른쪽", "Right") }

        // TokenUnit
        static var perMinute: String { tr("/분", "/min") }
        static var perSecond: String { tr("/초", "/sec") }
        static var rawValue: String { tr("원시값", "Raw") }

        // GraphTimeRange
        static var fiveMin: String { tr("5분", "5m") }
        static var tenMin: String { tr("10분", "10m") }
        static var thirtyMin: String { tr("30분", "30m") }
        static var oneHour: String { tr("1시간", "1h") }

        // ProviderDisplayMode
        static var aggregated: String { tr("합산", "Aggregated") }
        static var perProvider: String { tr("개별", "Per Provider") }

        // DashboardTimeRange
        static var sixHours: String { tr("6시간", "6h") }
        static var twelveHours: String { tr("12시간", "12h") }
        static var twentyFourHours: String { tr("24시간", "24h") }
        static var sevenDays: String { tr("7일", "7d") }
        static var fourteenDays: String { tr("14일", "14d") }
        static var thirtyDays: String { tr("30일", "30d") }

        // TimeRange (popover)
        static var halfHour: String { tr("30분", "30m") }
        static var today: String { tr("오늘", "Today") }
    }

    // MARK: - Colors

    enum color {
        static var orange: String { tr("주황", "Orange") }
        static var blue: String { tr("파랑", "Blue") }
        static var green: String { tr("초록", "Green") }
        static var purple: String { tr("보라", "Purple") }
        static var red: String { tr("빨강", "Red") }
        static var pink: String { tr("분홍", "Pink") }
        static var yellow: String { tr("노랑", "Yellow") }
        static var teal: String { tr("청록", "Teal") }
        static var indigo: String { tr("남색", "Indigo") }
        static var mint: String { tr("민트", "Mint") }
        static var cyan: String { tr("시안", "Cyan") }
        static var brown: String { tr("갈색", "Brown") }
        static var gray: String { tr("회색", "Gray") }
    }

    // MARK: - Usage countdown

    enum usage {
        static var resetSoon: String { tr("곧 초기화", "Reset soon") }
        static func countdown(days: Int, hours: Int) -> String {
            tr("\(days)일 \(hours)시간 후", "in \(days)d \(hours)h")
        }
        static func countdownHours(hours: Int, minutes: Int) -> String {
            tr("\(hours)시간 \(minutes)분 후", "in \(hours)h \(minutes)m")
        }
        static func countdownMinutes(_ minutes: Int) -> String {
            tr("\(minutes)분 후", "in \(minutes)m")
        }
    }
}
