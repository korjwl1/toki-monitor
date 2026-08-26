import Foundation

/// Reusable `DateFormatter`s, keyed by everything that changes their output.
///
/// Creating a `DateFormatter` is expensive — it builds an ICU pattern from the
/// locale and calendar every time. The call sites this exists for are inside
/// the plan-fit model builder, which runs per row and per period, and that
/// builder is invoked from a SwiftUI `body`. Rebuilding a formatter there put
/// the cost on every render of a 24/7 menu-bar app whose constitution budgets
/// idle CPU below 1%.
///
/// Main-actor confined because every caller already is: they read `L.code` to
/// pick the locale, and that resolves through `MainActor.assumeIsolated`.
@MainActor
enum FormatterCache {
    private struct Key: Hashable {
        let localeID: String
        let template: String
        let calendarID: String
        let timeZoneID: String
    }

    private static var cache: [Key: DateFormatter] = [:]

    /// A formatter for a localised template (`"MdE"`, `"yMMM"`, …).
    ///
    /// The template form is deliberate: `setLocalizedDateFormatFromTemplate`
    /// lets the region order the fields, which a hardcoded format string
    /// silently overrides — that mismatch already shipped once, as an axis
    /// reading 2:30 PM beside a tooltip reading 14:30.
    static func templated(
        _ template: String,
        localeID: String,
        calendar: Calendar? = nil
    ) -> DateFormatter {
        let key = Key(
            localeID: localeID,
            template: template,
            calendarID: calendar.map { "\($0.identifier)" } ?? "",
            timeZoneID: calendar?.timeZone.identifier ?? ""
        )
        if let hit = cache[key] { return hit }

        let f = DateFormatter()
        f.locale = Locale(identifier: localeID)
        if let calendar {
            f.calendar = calendar
            f.timeZone = calendar.timeZone
        }
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }

    /// The locale the app is currently presenting in.
    static var currentLocaleID: String { L.code == "ko" ? "ko_KR" : "en_US" }
}
