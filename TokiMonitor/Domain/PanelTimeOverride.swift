import Foundation

// MARK: - A panel on its own clock
//
// FR-037. Two panels of one dashboard often want different windows: a "last
// hour" gauge beside a 7-day trend, or this week beside the same week a year
// ago. Without per-panel time the only way to see both is two dashboards, and
// the reader then has to keep two time pickers in step by hand.
//
// The requirement has a second half that matters as much as the first: such a
// panel MUST SAY SO. A panel silently drawing a different window from the one
// the toolbar names is the worst kind of wrong number — it is right, about a
// question nobody asked.

enum PanelTimeOverride {

    /// The window this panel actually queries.
    ///
    /// Order matters: `relativeTime` REPLACES the dashboard's window, then
    /// `timeShift` moves whatever window resulted. "The last hour, a day ago"
    /// is a sentence; "a day ago, then the last hour" is not.
    static func effectiveTime(for panel: PanelConfig, dashboard: TimeConfig,
                              now: Date = Date()) -> TimeConfig {
        var time = dashboard
        if let relative = panel.relativeTime, let span = duration(relative), span > 0 {
            // Left relative on purpose. A panel that says "the last hour"
            // should still say it in an hour's time, which an absolute range
            // resolved now would not.
            time = TimeConfig(from: "now-\(relative)", to: "now")
        } else if panel.relativeTime != nil {
            // An unparseable token is ignored rather than guessed at, and the
            // panel keeps the dashboard's window. `label` still names it, so
            // the reader sees the typo rather than a silently normal panel.
            time = dashboard
        }
        guard let shift = panel.timeShift, let span = duration(shift), span > 0 else {
            return time
        }
        let from = time.isRelative ? now.addingTimeInterval(-time.duration) : time.fromDate
        let to = time.isRelative ? now : time.toDate
        return TimeConfig.absolute(from: from.addingTimeInterval(-span),
                                   to: to.addingTimeInterval(-span))
    }

    /// Whether this panel is on a window of its own at all.
    static func isOverridden(_ panel: PanelConfig) -> Bool {
        panel.relativeTime?.isEmpty == false || panel.timeShift?.isEmpty == false
    }

    /// What the panel's badge says, or nil when it is on the dashboard's own
    /// window.
    static func label(for panel: PanelConfig) -> String? {
        var parts: [String] = []
        if let relative = panel.relativeTime, !relative.isEmpty {
            parts.append(L.tr("최근 \(relative)", "last \(relative)"))
        }
        if let shift = panel.timeShift, !shift.isEmpty {
            parts.append(L.tr("\(shift) 전", "\(shift) earlier"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The same, spelled out for a screen reader — the badge is three
    /// characters and a tooltip, neither of which a VoiceOver reader gets.
    static func spokenLabel(for panel: PanelConfig) -> String? {
        guard let label = label(for: panel) else { return nil }
        return L.tr("이 패널은 대시보드와 다른 시간 범위를 봅니다: \(label)",
                    "This panel is on a different time range from the dashboard: \(label)")
    }

    /// A token whose value could not be read, so the reader can be told which.
    static func invalidTokens(of panel: PanelConfig) -> [String] {
        [panel.relativeTime, panel.timeShift]
            .compactMap { $0 }
            .filter { !$0.isEmpty && duration($0) == nil }
    }

    /// `"90s"`, `"30m"`, `"1h"`, `"7d"`, `"2w"` → seconds. Nil for anything
    /// else, including a bare number: "7" is ambiguous and a wrong guess here
    /// moves a whole panel's window.
    static func duration(_ token: String) -> TimeInterval? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()),
              value.isFinite, value >= 0
        else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3_600
        case "d": return value * 86_400
        case "w": return value * 7 * 86_400
        default:  return nil
        }
    }

    /// The tokens the editor offers. A closed list for the same reason the
    /// threshold colours are one: a free string that does not parse is a panel
    /// that quietly ignores its own setting.
    static let suggestedTokens = ["5m", "15m", "1h", "6h", "12h", "1d", "2d", "7d", "30d"]
}
