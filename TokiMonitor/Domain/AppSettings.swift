import Foundation
import ServiceManagement

// MARK: - Setting Enums

enum TextPosition: String, CaseIterable, Codable {
    case leading    // text LEFT of character
    case trailing   // text RIGHT of character

    var displayName: String {
        switch self {
        case .leading: "왼쪽"
        case .trailing: "오른쪽"
        }
    }
}

enum TokenUnit: String, CaseIterable, Codable {
    case perMinute   // "1.2K/m"
    case perSecond   // "20/s"
    case raw         // "1234"

    var displayName: String {
        switch self {
        case .perMinute: "/분"
        case .perSecond: "/초"
        case .raw: "원시값"
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
        case .fiveMinutes: "5분"
        case .tenMinutes: "10분"
        case .thirtyMinutes: "30분"
        case .oneHourGraph: "1시간"
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
}

enum ProviderDisplayMode: String, CaseIterable, Codable {
    case aggregated   // single status item, sum all
    case perProvider  // separate status item per provider

    var displayName: String {
        switch self {
        case .aggregated: "합산"
        case .perProvider: "개별"
        }
    }
}

// MARK: - Per-Provider Settings

struct ProviderSettings: Codable {
    var enabled: Bool = true
    var animationStyle: AnimationStyle? = nil   // nil = global default
    var customColorName: String? = nil          // nil = provider default
}

// MARK: - AppSettings

@MainActor
@Observable
final class AppSettings {
    var animationStyle: AnimationStyle {
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
    var launchAtLogin: Bool {
        didSet {
            updateLoginItem()
            save()
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        let ud = UserDefaults.standard
        animationStyle = Self.loadEnum(ud, key: "animationStyle") ?? .sparkline
        defaultTimeRange = Self.loadEnum(ud, key: "defaultTimeRange") ?? .oneHour
        showRateText = ud.bool(forKey: "showRateText")
        textPosition = Self.loadEnum(ud, key: "textPosition") ?? .trailing
        tokenUnit = Self.loadEnum(ud, key: "tokenUnit") ?? .perMinute
        graphTimeRange = Self.loadEnum(ud, key: "graphTimeRange") ?? .oneHourGraph
        providerDisplayMode = Self.loadEnum(ud, key: "providerDisplayMode") ?? .aggregated
        providerSettingsMap = Self.loadProviderSettings(ud)
        aggregatedColorName = ud.string(forKey: "aggregatedColorName")
        launchAtLogin = ud.bool(forKey: "launchAtLogin")
    }

    /// Get effective settings for a provider, falling back to defaults.
    func effectiveSettings(for providerId: String) -> ProviderSettings {
        providerSettingsMap[providerId] ?? ProviderSettings()
    }

    func effectiveStyle(for providerId: String) -> AnimationStyle {
        effectiveSettings(for: providerId).animationStyle ?? animationStyle
    }

    func effectiveColorName(for provider: ProviderInfo) -> String {
        effectiveSettings(for: provider.id).customColorName ?? provider.colorName
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(animationStyle.rawValue, forKey: "animationStyle")
        defaults.set(defaultTimeRange.rawValue, forKey: "defaultTimeRange")
        defaults.set(showRateText, forKey: "showRateText")
        defaults.set(textPosition.rawValue, forKey: "textPosition")
        defaults.set(tokenUnit.rawValue, forKey: "tokenUnit")
        defaults.set(graphTimeRange.rawValue, forKey: "graphTimeRange")
        defaults.set(providerDisplayMode.rawValue, forKey: "providerDisplayMode")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(aggregatedColorName, forKey: "aggregatedColorName")

        if let data = try? JSONEncoder().encode(providerSettingsMap) {
            defaults.set(data, forKey: "providerSettings")
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

    private static func loadProviderSettings(_ ud: UserDefaults) -> [String: ProviderSettings] {
        guard let data = ud.data(forKey: "providerSettings"),
              let map = try? JSONDecoder().decode([String: ProviderSettings].self, from: data)
        else { return [:] }
        return map
    }
}
