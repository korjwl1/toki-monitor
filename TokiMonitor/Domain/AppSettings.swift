import Foundation
import ServiceManagement

// MARK: - Language

enum AppLanguage: String, CaseIterable, Codable {
    case system
    case ko
    case en

    var displayName: String {
        switch self {
        case .system: "시스템 기본"
        case .ko: "한국어"
        case .en: "English"
        }
    }

    /// Resolved language code based on system locale when set to .system
    var resolvedCode: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? "ko" : "en"
        case .ko: return "ko"
        case .en: return "en"
        }
    }
}

// MARK: - Setting Enums

enum TextPosition: String, CaseIterable, Codable {
    case leading    // text LEFT of character
    case trailing   // text RIGHT of character

    var displayName: String {
        switch self {
        case .leading: L.enumStr.left
        case .trailing: L.enumStr.right
        }
    }
}

enum TokenUnit: String, CaseIterable, Codable {
    case perMinute   // "1.2K/m"
    case perSecond   // "20/s"
    case raw         // "1234"

    var displayName: String {
        switch self {
        case .perMinute: L.enumStr.perMinute
        case .perSecond: L.enumStr.perSecond
        case .raw: L.enumStr.rawValue
        }
    }
}

enum GraphTimeRange: String, CaseIterable, Codable {
    case fiveMinutes     // 30 samples x 10s
    case tenMinutes      // 30 samples x 20s
    case thirtyMinutes   // 30 samples x 60s
    case oneHourGraph    // 30 samples x 120s

    var displayName: String {
        switch self {
        case .fiveMinutes: L.enumStr.fiveMin
        case .tenMinutes: L.enumStr.tenMin
        case .thirtyMinutes: L.enumStr.thirtyMin
        case .oneHourGraph: L.enumStr.oneHour
        }
    }

    var sampleInterval: TimeInterval {
        switch self {
        case .fiveMinutes: 10.0
        case .tenMinutes: 20.0
        case .thirtyMinutes: 60.0
        case .oneHourGraph: 120.0
        }
    }

    /// PromQL time bucket matching bin width.
    var promqlBucket: String {
        switch self {
        case .fiveMinutes: "10s"
        case .tenMinutes: "20s"
        case .thirtyMinutes: "1m"
        case .oneHourGraph: "2m"
        }
    }

    /// Since timestamp for PromQL query (YYYYMMDDHHmmss, UTC).
    var sinceTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        // 30 bins * sampleInterval = total window + small buffer
        let duration = Double(30) * sampleInterval + sampleInterval
        return formatter.string(from: Date().addingTimeInterval(-duration))
    }
}

enum ProviderDisplayMode: String, CaseIterable, Codable {
    case aggregated   // single status item, sum all
    case perProvider  // separate status item per provider

    var displayName: String {
        switch self {
        case .aggregated: L.enumStr.aggregated
        case .perProvider: L.enumStr.perProvider
        }
    }
}

enum SleepDelay: String, CaseIterable, Codable {
    case thirtySeconds
    case oneMinute
    case ninetySeconds
    case twoMinutes

    var displayName: String {
        switch self {
        case .thirtySeconds: L.tr("30초", "30s")
        case .oneMinute: L.tr("1분", "1m")
        case .ninetySeconds: L.tr("1분 30초", "1m 30s")
        case .twoMinutes: L.tr("2분", "2m")
        }
    }

    var interval: TimeInterval {
        switch self {
        case .thirtySeconds: 30
        case .oneMinute: 60
        case .ninetySeconds: 90
        case .twoMinutes: 120
        }
    }
}

enum AlertMode: String, CaseIterable, Codable {
    case iconColor
    case notification
    case both

    var displayName: String {
        switch self {
        case .iconColor: L.tr("아이콘 색상", "Icon Color")
        case .notification: L.tr("시스템 알림", "Notification")
        case .both: L.tr("둘 다", "Both")
        }
    }
}

// MARK: - HP Bar Source

enum HPBarSource: String, CaseIterable, Codable {
    case none
    case claudeFiveHour
    case claudeSevenDay
    case codexSevenDay

    var displayName: String {
        switch self {
        case .none: L.tr("없음", "None")
        case .claudeFiveHour: L.tr("Claude 5시간", "Claude 5h")
        case .claudeSevenDay: L.tr("Claude 7일", "Claude 7d")
        case .codexSevenDay: L.tr("Codex 7일", "Codex 7d")
        }
    }

    var providerId: String? {
        switch self {
        case .none: nil
        case .claudeFiveHour, .claudeSevenDay: "anthropic"
        case .codexSevenDay: "openai"
        }
    }
}

// MARK: - Per-Provider Settings

struct ProviderSettings: Codable {
    var enabled: Bool = true
    var animationStyle: AnimationStyle? = nil   // nil = global default
    var customColorName: String? = nil          // nil = provider default
    var widgetOrder: [MenuWidgetItem]? = nil    // nil = default order
    var hpBarSource: HPBarSource? = nil         // nil = global default
}

// MARK: - Menu Bar Widget Order

struct MenuWidgetItem: Codable, Identifiable, Equatable {
    var id: String          // provider id or "claude_usage"
    var visible: Bool = true

    static let claudeUsageId = "claude_usage"
    static let codexUsageId = "codex_usage"
}

// MARK: - AppSettings

@MainActor
@Observable
final class AppSettings {
    var animationThemeId: String {
        didSet { save() }
    }
    var animationStyle: AnimationStyle {
        didSet { save() }
    }
    var hpBarSource: HPBarSource {
        didSet { save() }
    }
    var sleepDelay: SleepDelay {
        didSet { save() }
    }
    var defaultTimeRange: TimeRange {
        didSet { save() }
    }
    var showRateText: Bool {
        didSet { save() }
    }
    var textPosition: TextPosition {
        didSet { save() }
    }
    var tokenUnit: TokenUnit {
        didSet { save() }
    }
    var graphTimeRange: GraphTimeRange {
        didSet { save() }
    }
    var providerDisplayMode: ProviderDisplayMode {
        didSet { save() }
    }
    var providerSettingsMap: [String: ProviderSettings] {
        didSet { save() }
    }
    /// 합산 모드에서의 아이콘 색상. nil = 흰색(template)
    var aggregatedColorName: String? {
        didSet { save() }
    }
    /// Menu bar widget order and visibility.
    var widgetOrder: [MenuWidgetItem] {
        didSet { save() }
    }
    /// Signal to request popup re-show from settings. Not persisted.
    /// .mostActive = pick provider with most recent traces, .provider(id) = specific one
    enum PopupRequest: Equatable {
        case mostActive
        case provider(String)
    }
    var pendingPopupRequest: PopupRequest?

    // Anomaly detection
    var velocityAlertEnabled: Bool {
        didSet { save() }
    }
    var velocityThreshold: Double {
        didSet { save() }
    }
    var velocityAlertColor: String {
        didSet { save() }
    }
    var velocityAlertMode: AlertMode {
        didSet { save() }
    }
    var historicalAlertEnabled: Bool {
        didSet { save() }
    }
    var historicalMultiplier: Double {
        didSet { save() }
    }
    var historicalAlertColor: String {
        didSet { save() }
    }
    var historicalAlertMode: AlertMode {
        didSet { save() }
    }

    var claudeAlert75: Bool {
        didSet { save() }
    }
    var claudeAlert90: Bool {
        didSet { save() }
    }
    var language: AppLanguage {
        didSet { save() }
    }
    var launchAtLogin: Bool {
        didSet {
            updateLoginItem()
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private var pendingSave: DispatchWorkItem?

    init() {
        let ud = UserDefaults.standard
        animationThemeId = ud.string(forKey: "animationThemeId") ?? "rabbit"
        animationStyle = Self.loadEnum(ud, key: "animationStyle") ?? .sparkline
        hpBarSource = Self.loadEnum(ud, key: "hpBarSource") ?? .none
        sleepDelay = Self.loadEnum(ud, key: "sleepDelay") ?? .twoMinutes
        defaultTimeRange = Self.loadEnum(ud, key: "defaultTimeRange") ?? .oneHour
        showRateText = ud.bool(forKey: "showRateText")
        textPosition = Self.loadEnum(ud, key: "textPosition") ?? .trailing
        tokenUnit = Self.loadEnum(ud, key: "tokenUnit") ?? .perMinute
        graphTimeRange = Self.loadEnum(ud, key: "graphTimeRange") ?? .oneHourGraph
        providerDisplayMode = Self.loadEnum(ud, key: "providerDisplayMode") ?? .aggregated
        providerSettingsMap = Self.loadProviderSettings(ud)
        aggregatedColorName = ud.string(forKey: "aggregatedColorName")
        widgetOrder = Self.loadWidgetOrder(ud)
        velocityAlertEnabled = ud.bool(forKey: "velocityAlertEnabled")
        velocityThreshold = ud.object(forKey: "velocityThreshold") as? Double ?? 0.50
        velocityAlertColor = ud.string(forKey: "velocityAlertColor") ?? "red"
        velocityAlertMode = Self.loadEnum(ud, key: "velocityAlertMode") ?? .iconColor
        historicalAlertEnabled = ud.bool(forKey: "historicalAlertEnabled")
        historicalMultiplier = ud.object(forKey: "historicalMultiplier") as? Double ?? 3.0
        historicalAlertColor = ud.string(forKey: "historicalAlertColor") ?? "orange"
        historicalAlertMode = Self.loadEnum(ud, key: "historicalAlertMode") ?? .iconColor
        claudeAlert75 = ud.object(forKey: "claudeAlert75") as? Bool ?? true
        claudeAlert90 = ud.object(forKey: "claudeAlert90") as? Bool ?? true
        language = Self.loadEnum(ud, key: "language") ?? .system
        launchAtLogin = ud.bool(forKey: "launchAtLogin")
    }

    /// Get effective settings for a provider, falling back to defaults.
    func effectiveSettings(for providerId: String) -> ProviderSettings {
        providerSettingsMap[providerId] ?? ProviderSettings()
    }

    /// Toggle a provider's enabled state and sync with toki CLI.
    func setProviderEnabled(_ providerId: String, enabled: Bool, tokiProviderId: String?) {
        var ps = effectiveSettings(for: providerId)
        ps.enabled = enabled
        providerSettingsMap[providerId] = ps

        // Sync with toki daemon when enabling
        if enabled, let tokiId = tokiProviderId {
            Task { try? await TokiSettingsRunner().addProvider(tokiId) }
        }
    }

    func effectiveStyle(for providerId: String) -> AnimationStyle {
        effectiveSettings(for: providerId).animationStyle ?? animationStyle
    }

    func effectiveColorName(for provider: ProviderInfo) -> String {
        effectiveSettings(for: provider.id).customColorName ?? provider.colorName
    }

    // MARK: - Persistence

    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performSave()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func performSave() {
        defaults.set(animationThemeId, forKey: "animationThemeId")
        defaults.set(animationStyle.rawValue, forKey: "animationStyle")
        defaults.set(hpBarSource.rawValue, forKey: "hpBarSource")
        defaults.set(sleepDelay.rawValue, forKey: "sleepDelay")
        defaults.set(defaultTimeRange.rawValue, forKey: "defaultTimeRange")
        defaults.set(showRateText, forKey: "showRateText")
        defaults.set(textPosition.rawValue, forKey: "textPosition")
        defaults.set(tokenUnit.rawValue, forKey: "tokenUnit")
        defaults.set(graphTimeRange.rawValue, forKey: "graphTimeRange")
        defaults.set(providerDisplayMode.rawValue, forKey: "providerDisplayMode")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(aggregatedColorName, forKey: "aggregatedColorName")
        defaults.set(velocityAlertEnabled, forKey: "velocityAlertEnabled")
        defaults.set(velocityThreshold, forKey: "velocityThreshold")
        defaults.set(velocityAlertColor, forKey: "velocityAlertColor")
        defaults.set(velocityAlertMode.rawValue, forKey: "velocityAlertMode")
        defaults.set(historicalAlertEnabled, forKey: "historicalAlertEnabled")
        defaults.set(historicalMultiplier, forKey: "historicalMultiplier")
        defaults.set(historicalAlertColor, forKey: "historicalAlertColor")
        defaults.set(historicalAlertMode.rawValue, forKey: "historicalAlertMode")
        defaults.set(claudeAlert75, forKey: "claudeAlert75")
        defaults.set(claudeAlert90, forKey: "claudeAlert90")
        defaults.set(language.rawValue, forKey: "language")

        if let data = try? JSONEncoder().encode(providerSettingsMap) {
            defaults.set(data, forKey: "providerSettings")
        }
        if let data = try? JSONEncoder().encode(widgetOrder) {
            defaults.set(data, forKey: "widgetOrder")
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail — user can retry
        }
    }

    // MARK: - Loading

    private static func loadEnum<T: RawRepresentable>(
        _ ud: UserDefaults, key: String
    ) -> T? where T.RawValue == String {
        guard let raw = ud.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    /// Returns resolved widget order for a specific provider's panel (per-provider mode).
    func resolvedProviderWidgetOrder(for providerId: String) -> [MenuWidgetItem] {
        let isAnthropic = providerId == "anthropic"
        let isOpenAI = providerId == "openai"
        let ps = effectiveSettings(for: providerId)

        var items: [MenuWidgetItem]
        if let saved = ps.widgetOrder {
            items = saved.filter { item in
                if item.id == MenuWidgetItem.claudeUsageId { return isAnthropic }
                if item.id == MenuWidgetItem.codexUsageId { return isOpenAI }
                return true
            }
        } else {
            items = [MenuWidgetItem(id: providerId)]
            if isAnthropic {
                items.append(MenuWidgetItem(id: MenuWidgetItem.claudeUsageId))
            }
            if isOpenAI {
                items.append(MenuWidgetItem(id: MenuWidgetItem.codexUsageId))
            }
        }

        // Ensure provider itself is present
        if !items.contains(where: { $0.id == providerId }) {
            items.insert(MenuWidgetItem(id: providerId), at: 0)
        }
        if isAnthropic, !items.contains(where: { $0.id == MenuWidgetItem.claudeUsageId }) {
            items.append(MenuWidgetItem(id: MenuWidgetItem.claudeUsageId))
        }
        if isOpenAI, !items.contains(where: { $0.id == MenuWidgetItem.codexUsageId }) {
            items.append(MenuWidgetItem(id: MenuWidgetItem.codexUsageId))
        }

        return items
    }

    private static func loadWidgetOrder(_ ud: UserDefaults) -> [MenuWidgetItem] {
        guard let data = ud.data(forKey: "widgetOrder"),
              let items = try? JSONDecoder().decode([MenuWidgetItem].self, from: data)
        else { return [] }
        return items
    }

    /// Returns resolved widget order, filling in any missing providers/claude_usage.
    func resolvedWidgetOrder() -> [MenuWidgetItem] {
        let enabledProviderIds = ProviderRegistry.configurableProviders
            .filter { effectiveSettings(for: $0.id).enabled }
            .map(\.id)

        var result = widgetOrder.filter { item in
            if item.id == MenuWidgetItem.claudeUsageId { return true }
            return enabledProviderIds.contains(item.id)
        }

        // Add missing enabled providers
        for pid in enabledProviderIds where !result.contains(where: { $0.id == pid }) {
            result.append(MenuWidgetItem(id: pid))
        }

        // Add claude_usage if missing
        if !result.contains(where: { $0.id == MenuWidgetItem.claudeUsageId }) {
            result.append(MenuWidgetItem(id: MenuWidgetItem.claudeUsageId))
        }

        // Add codex_usage if missing
        if !result.contains(where: { $0.id == MenuWidgetItem.codexUsageId }) {
            result.append(MenuWidgetItem(id: MenuWidgetItem.codexUsageId))
        }

        return result
    }

    private static func loadProviderSettings(_ ud: UserDefaults) -> [String: ProviderSettings] {
        guard let data = ud.data(forKey: "providerSettings"),
              let map = try? JSONDecoder().decode([String: ProviderSettings].self, from: data)
        else { return [:] }
        return map
    }
}
