import Foundation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    var animationStyle: AnimationStyle {
        didSet { save() }
    }
    var defaultTimeRange: TimeRange {
        didSet { save() }
    }
    var launchAtLogin: Bool {
        didSet {
            updateLoginItem()
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let styleKey = "animationStyle"
    private let rangeKey = "defaultTimeRange"
    private let loginKey = "launchAtLogin"

    init() {
        animationStyle = Self.loadStyle(from: UserDefaults.standard)
        defaultTimeRange = Self.loadTimeRange(from: UserDefaults.standard)
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
    }

    private func save() {
        defaults.set(animationStyle.rawValue, forKey: styleKey)
        defaults.set(defaultTimeRange.rawValue, forKey: rangeKey)
        defaults.set(launchAtLogin, forKey: loginKey)
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

    private static func loadStyle(from defaults: UserDefaults) -> AnimationStyle {
        guard let raw = defaults.string(forKey: "animationStyle"),
              let style = AnimationStyle(rawValue: raw) else {
            return .sparkline
        }
        return style
    }

    private static func loadTimeRange(from defaults: UserDefaults) -> TimeRange {
        guard let raw = defaults.string(forKey: "defaultTimeRange"),
              let range = TimeRange(rawValue: raw) else {
            return .oneHour
        }
        return range
    }
}
