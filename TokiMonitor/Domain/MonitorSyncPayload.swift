import Foundation

// MARK: - What travels on the monitor settings channel
//
// Two kinds of thing, each under its own key:
//
//   dashboard:<uid>   one dashboard, in the EXPORT shape
//   prefs:monitor     the display preferences, as one snapshot
//
// The dashboard payload is `DashboardExchange.exportData` verbatim, not a
// second serialisation. That format was made complete and lossless for 계약 C3
// and it already excludes query results, usage and cost; a private wire format
// here would be a second idea of what a dashboard is, free to drift out of step
// with the real one and to quietly stop carrying a field.

/// The key namespace on the server.
enum MonitorSyncKey {
    static let dashboardPrefix = "dashboard:"
    static let preferences = "prefs:monitor"

    /// The key a dashboard is stored under, or nil when its uid cannot be one.
    ///
    /// A uid this app generates is eight lowercase alphanumerics, but a
    /// dashboard that arrived by import carries whatever uid it was written
    /// with. Rather than rewrite it — which would change the identity two
    /// machines agree on and let one dashboard overwrite another — such a
    /// dashboard simply does not sync, and is reported as not syncing.
    static func dashboard(uid: String) -> String? {
        let key = dashboardPrefix + uid
        return MonitorSettingsLimits.isValidKey(key) ? key : nil
    }

    static func dashboardUID(fromKey key: String) -> String? {
        guard key.hasPrefix(dashboardPrefix) else { return nil }
        let uid = String(key.dropFirst(dashboardPrefix.count))
        return uid.isEmpty ? nil : uid
    }

    static func isDashboard(_ key: String) -> Bool { key.hasPrefix(dashboardPrefix) }
}

// MARK: - Preferences snapshot

/// The monitor's display preferences as one opaque blob.
///
/// Each value carries its own type tag, because `UserDefaults` holds `Bool`,
/// `Int`, `Double`, `String` and `Data` and JSON cannot tell a `Bool` from an
/// `Int` on the way back. Reading `showRateText` back as `1` and writing it
/// into a `Bool` preference is the kind of quiet corruption that only shows up
/// as "my menu bar looks different on the other Mac".
enum MonitorPrefsSnapshot {

    static let schemaVersion = 1

    /// The preferences that travel.
    ///
    /// An allowlist rather than "everything in the domain", for two reasons.
    /// Some of what lives in `UserDefaults` is about THIS machine and must not
    /// be imposed on another (`launchAtLogin` registers a login item; the
    /// usage-alert dedupe state is about notifications already shown here).
    /// And dashboards have their own keys — carrying them here as well would
    /// give the same document two homes on the server and two chances to
    /// disagree.
    static let syncedKeys: [String] = [
        "animationThemeId",
        "animationStyle",
        "hpBarSource",
        "sleepDelay",
        "defaultTimeRange",
        "showRateText",
        "textPosition",
        "tokenUnit",
        "graphTimeRange",
        "providerDisplayMode",
        "aggregatedColorName",
        "velocityAlertEnabled",
        "velocityThreshold",
        "historicalAlertEnabled",
        "historicalMultiplier",
        "usageAlert75Enabled",
        "usageAlert90Enabled",
        "language",
        "providerSettings",
        "widgetOrder",
        "usageAlert75Buckets",
        "usageAlert90Buckets",
        "claudeUsageWidgetBuckets",
        "codexUsageWidgetWindows",
    ]

    /// Persisted preferences this channel deliberately leaves alone, and why.
    /// Named rather than merely absent so that a later reader can tell an
    /// omission from an oversight.
    static let deliberatelyLocal: [String: String] = [
        "launchAtLogin": "registers a login item on THIS Mac",
        "usageAlertNotifiedResets": "records which notifications this Mac already showed",
        "dashboardConfig": "dashboards travel under their own keys",
        "dashboardList": "dashboards travel under their own keys",
        "activeDashboardUID": "which dashboard is open is a per-machine choice",
        "datasourceInstances": "a datasource can name a server only this network reaches",
    ]

    /// Where entries from a build that knows more preferences than this one are
    /// kept, so that pushing from here does not delete them.
    static let foreignStoreKey = "monitorSyncForeignPrefs"

    // MARK: Capture

    /// Read the synced preferences out of `defaults` and encode them.
    ///
    /// `foreign` is merged back in: entries a NEWER build wrote that this one
    /// has no name for. Without that, opening the older build once would push a
    /// snapshot missing them and the newer machine would lose those settings on
    /// its next pull — the round trip itself becoming the thing that drops
    /// them.
    static func capture(from defaults: UserDefaults) -> String? {
        var values: [String: Any] = [:]
        for key in syncedKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            guard let tagged = tag(raw) else { continue }
            values[key] = tagged
        }
        for (key, value) in foreign(in: defaults) where values[key] == nil {
            values[key] = value
        }

        let document: [String: Any] = ["schema": schemaVersion, "values": values]
        guard let data = try? JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Apply

    /// What applying a snapshot would change, worked out without changing it.
    struct Application: Equatable {
        /// Keys whose local value differs from the snapshot's.
        var changing: [String] = []
        /// Keys the snapshot carries that this build has no name for. They are
        /// kept aside rather than written into preferences.
        var foreign: [String] = []
        var isNoOp: Bool { changing.isEmpty && foreign.isEmpty }
    }

    /// Decode a snapshot, or nil when it is not one. A nil here must never be
    /// treated as an empty snapshot: an empty one would erase preferences.
    static func decode(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let values = object["values"] as? [String: Any]
        else { return nil }
        return values
    }

    /// Write a snapshot into `defaults`.
    ///
    /// Returns nil when the payload is not a snapshot — in which case NOTHING
    /// is written. A half-applied preference set is worse than an unapplied
    /// one, so the whole document is read and every value converted before the
    /// first write happens.
    @discardableResult
    static func apply(_ payload: String, to defaults: UserDefaults) -> Application? {
        guard let values = decode(payload) else { return nil }

        var writes: [(String, Any)] = []
        var report = Application()
        var foreignEntries: [String: Any] = [:]

        for (key, tagged) in values {
            guard syncedKeys.contains(key), let value = untag(tagged) else {
                // A preference from a build that knows more than this one.
                // Writing it blind would put an unvalidated value into a
                // preference this build might later read as a different type.
                foreignEntries[key] = tagged
                report.foreign.append(key)
                continue
            }
            if !equal(defaults.object(forKey: key), value) {
                report.changing.append(key)
            }
            writes.append((key, value))
        }

        for (key, value) in writes { defaults.set(value, forKey: key) }
        setForeign(foreignEntries, in: defaults)

        report.changing.sort()
        report.foreign.sort()
        return report
    }

    // MARK: Foreign entries

    static func foreign(in defaults: UserDefaults) -> [String: Any] {
        guard let data = defaults.data(forKey: foreignStoreKey),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func setForeign(_ entries: [String: Any], in defaults: UserDefaults) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: foreignStoreKey)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries) else { return }
        defaults.set(data, forKey: foreignStoreKey)
    }

    // MARK: Type tagging

    /// `Data` goes as base64 and says so; the rest carry their kind so the
    /// value that comes back is the value that went out.
    private static func tag(_ raw: Any) -> [String: Any]? {
        if let data = raw as? Data { return ["t": "d", "v": data.base64EncodedString()] }
        if let string = raw as? String { return ["t": "s", "v": string] }
        if let number = raw as? NSNumber {
            // CFBoolean is an NSNumber; the objCType is the only way to tell.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return ["t": "b", "v": number.boolValue]
            }
            if strcmp(number.objCType, "d") == 0 || strcmp(number.objCType, "f") == 0 {
                return ["t": "f", "v": number.doubleValue]
            }
            return ["t": "i", "v": number.int64Value]
        }
        return nil
    }

    private static func untag(_ tagged: Any) -> Any? {
        guard let entry = tagged as? [String: Any],
              let type = entry["t"] as? String,
              let value = entry["v"] else { return nil }
        switch type {
        case "s": return value as? String
        case "b": return (value as? NSNumber)?.boolValue
        case "i": return (value as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        case "f": return (value as? NSNumber)?.doubleValue
        case "d": return (value as? String).flatMap { Data(base64Encoded: $0) }
        default:  return nil
        }
    }

    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l as Data, r as Data): return l == r
        case let (l as NSNumber, r as NSNumber): return l == r
        case let (l as String, r as String): return l == r
        default: return false
        }
    }
}

// MARK: - Dashboards on the wire

enum MonitorDashboardPayload {

    /// A dashboard as it goes to the server: the export shape, unchanged.
    ///
    /// A document written against a schema beyond this build goes as the bytes
    /// it arrived as (계약 C2). Re-encoding it would let this build decide what
    /// a future schema looks like, and a sync round trip would become the thing
    /// that finally drops the keys the store has been carefully preserving.
    @MainActor
    static func encode(_ config: DashboardConfig) throws -> String {
        if config.isReadOnlyForThisBuild,
           let original = DashboardConfigStore.originalBytes(forUID: config.uid) {
            return String(decoding: original, as: UTF8.self)
        }
        return try DashboardExchange.exportString(config)
    }

    /// A dashboard as it comes back.
    ///
    /// Unlike a file import, this does NOT refuse a document from a newer
    /// schema. An import can refuse because the user still has the file and can
    /// upgrade and try again; refusing here would mean the entry sits on the
    /// server unreachable, and any later push from this machine would have to
    /// either overwrite it or stall forever. So it is decoded as far as it
    /// goes, its original bytes are remembered, and the store writes those
    /// bytes back untouched — the same read-only path a future-schema document
    /// already takes on disk.
    @MainActor
    static func decode(_ payload: String) throws -> DashboardConfig {
        guard let data = payload.data(using: .utf8) else {
            throw DashboardExchange.ImportRefusal.unreadable(
                L.tr("페이로드가 텍스트가 아닙니다", "the payload is not text")
            )
        }
        let config = try DashboardExchange.decodeIgnoringSchemaGate(data)
        DashboardConfigStore.rememberOriginal(config, bytes: data)
        return config
    }

    /// A one-line description of a dashboard, for a conflict the user has to
    /// decide. Never its query strings — the point is to identify the document,
    /// not to reprint it.
    @MainActor
    static func summary(_ config: DashboardConfig) -> String {
        L.tr("패널 \(config.panels.count)개 · 변수 \(config.templating.list.count)개 · 스키마 v\(config.schemaVersion)",
             "\(config.panels.count) panels · \(config.templating.list.count) variables · schema v\(config.schemaVersion)")
    }
}
