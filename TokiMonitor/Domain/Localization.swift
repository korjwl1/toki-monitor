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
        // Chart axis labels
        static var axisTime: String { tr("시간", "Time") }
        static var axisTokens: String { tr("토큰", "Tokens") }
        static var axisCost: String { tr("비용", "Cost") }
        static var axisModel: String { tr("모델", "Model") }
        static var axisCalls: String { tr("호출", "Calls") }
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
