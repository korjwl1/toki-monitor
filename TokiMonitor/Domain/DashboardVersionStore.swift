import Foundation

/// Manages dashboard version history. Stores versions in UserDefaults.
@MainActor
final class DashboardVersionStore {
    private static let storeKey = "dashboardVersions"
    private static let maxVersionsPerDashboard = 50

    func saveVersion(for dashboard: DashboardConfig, message: String = "") {
        var versions = loadAllVersions()
        let existingCount = versions.filter { $0.dashboardUID == dashboard.uid }.count
        let version = DashboardVersion(
            dashboardUID: dashboard.uid,
            version: existingCount + 1,
            config: dashboard,
            message: message
        )
        versions.append(version)

        // Trim old versions
        let dashboardVersions = versions.filter { $0.dashboardUID == dashboard.uid }
        if dashboardVersions.count > Self.maxVersionsPerDashboard {
            let toRemove = dashboardVersions
                .sorted { $0.version < $1.version }
                .prefix(dashboardVersions.count - Self.maxVersionsPerDashboard)
            let removeIDs = Set(toRemove.map(\.id))
            versions.removeAll { removeIDs.contains($0.id) }
        }

        saveAllVersions(versions)
    }

    func versions(for dashboardUID: String) -> [DashboardVersion] {
        loadAllVersions()
            .filter { $0.dashboardUID == dashboardUID }
            .sorted { $0.version > $1.version }
    }

    func restoreVersion(_ version: DashboardVersion) -> DashboardConfig {
        var config = version.config
        config.version = version.version
        return config
    }

    func deleteVersions(for dashboardUID: String) {
        var versions = loadAllVersions()
        versions.removeAll { $0.dashboardUID == dashboardUID }
        saveAllVersions(versions)
    }

    // MARK: - Diff

    func diffVersions(_ v1: DashboardVersion, _ v2: DashboardVersion) -> [(field: String, old: String, new: String)] {
        var diffs: [(field: String, old: String, new: String)] = []
        let c1 = v1.config
        let c2 = v2.config

        if c1.title != c2.title {
            diffs.append((L.tr("제목", "Title"), c1.title, c2.title))
        }
        if c1.description != c2.description {
            diffs.append((L.tr("설명", "Description"), c1.description ?? "-", c2.description ?? "-"))
        }
        if c1.panels.count != c2.panels.count {
            diffs.append((L.tr("패널 수", "Panel count"), "\(c1.panels.count)", "\(c2.panels.count)"))
        }
        if c1.time != c2.time {
            diffs.append((L.tr("시간 범위", "Time range"), c1.time.from, c2.time.from))
        }
        if c1.refresh != c2.refresh {
            diffs.append((L.tr("새로고침", "Refresh"), c1.refresh.displayName, c2.refresh.displayName))
        }
        if c1.tags != c2.tags {
            diffs.append((L.tr("태그", "Tags"), c1.tags.joined(separator: ", "), c2.tags.joined(separator: ", ")))
        }

        return diffs
    }

    // MARK: - Persistence

    /// Decoded entries, plus the raw bytes of any entry this build could not
    /// read. The split matters because the caller writes the whole array back:
    /// an all-or-nothing decode turns one unreadable entry into the silent
    /// deletion of every version the user has, and unlike the dashboard list
    /// there is nothing else holding a copy.
    private func loadAllVersionsPreservingUnreadable()
        -> (versions: [DashboardVersion], unreadable: [Any]) {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return ([], []) }

        var decoded: [DashboardVersion] = []
        var unreadable: [Any] = []
        for element in raw {
            guard let bytes = try? JSONSerialization.data(withJSONObject: element),
                  let one = try? JSONDecoder().decode(DashboardVersion.self, from: bytes)
            else {
                unreadable.append(element)
                continue
            }
            decoded.append(one)
        }
        return (decoded, unreadable)
    }

    private func loadAllVersions() -> [DashboardVersion] {
        loadAllVersionsPreservingUnreadable().versions
    }

    /// Writes `versions` back, re-appending verbatim anything the load could
    /// not decode. Without this, saving is how the history gets destroyed.
    private func saveAllVersions(_ versions: [DashboardVersion]) {
        let unreadable = loadAllVersionsPreservingUnreadable().unreadable
        guard let encoded = try? JSONEncoder().encode(versions) else { return }

        guard !unreadable.isEmpty else {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
            return
        }
        guard var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any] else {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
            return
        }
        merged.append(contentsOf: unreadable)
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else {
            UserDefaults.standard.set(encoded, forKey: Self.storeKey)
            return
        }
        UserDefaults.standard.set(out, forKey: Self.storeKey)
    }
}
