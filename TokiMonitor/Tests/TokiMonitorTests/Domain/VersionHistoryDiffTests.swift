import Foundation
import Testing
@testable import TokiMonitor

/// The two halves of `DashboardVersionStore` that decide anything without
/// going near `UserDefaults`: what "restore this version" produces, and what
/// the version-history screen tells the user changed between two versions.
///
/// The persistence half is not here on purpose. The store reads and writes
/// `UserDefaults.standard`, and because the test target runs inside the app as
/// its host, `UserDefaults.standard` in a test *is* the live `com.toki.monitor`
/// domain holding the user's real dashboards. Covering `saveVersion`,
/// `versions(for:)` and `deleteVersions(for:)` needs an injectable defaults
/// object; without one, running them would edit the user's data.
@MainActor
@Suite("Dashboard version restore and diff")
struct VersionHistoryDiffTests {

    private func config(
        title: String = "Tokens",
        description: String? = nil,
        tags: [String] = [],
        panels: Int = 0,
        from: String = "now-24h",
        refresh: RefreshInterval = .off,
        version: Int = 1
    ) -> DashboardConfig {
        var c = DashboardConfig()
        c.uid = "fixed-uid"
        c.title = title
        c.description = description
        c.tags = tags
        c.time = TimeConfig(from: from, to: "now")
        c.refresh = refresh
        c.version = version
        c.panels = (0..<panels).map { i in
            PanelConfig(title: "panel \(i)", panelType: .stat, metric: .totalTokens,
                        gridPosition: GridPosition(column: 0, row: i, width: 6, height: 1))
        }
        return c
    }

    private func version(_ n: Int, _ config: DashboardConfig) -> DashboardVersion {
        DashboardVersion(dashboardUID: config.uid, version: n, config: config)
    }

    // MARK: - Restore

    @Test("Restoring stamps the restored config with the version number it came from")
    func restoreStampsVersion() {
        let store = DashboardVersionStore()
        // The stored config still carries whatever `version` it had when it was
        // saved. If restore handed that back untouched, the dashboard would
        // claim to be a version it is not, and the next save would number the
        // history from the wrong place.
        let saved = config(title: "Tokens", version: 1)
        let restored = store.restoreVersion(version(7, saved))

        #expect(restored.version == 7)
        #expect(restored.title == "Tokens")
        #expect(restored.uid == saved.uid, "restoring must not fork the dashboard identity")
    }

    @Test("Restoring changes nothing but the version number")
    func restoreIsOtherwiseFaithful() {
        let store = DashboardVersionStore()
        let saved = config(title: "Cost", description: "spend", tags: ["a", "b"], panels: 3,
                           from: "now-7d", refresh: .thirtySeconds, version: 2)
        var restored = store.restoreVersion(version(4, saved))

        restored.version = saved.version
        #expect(restored == saved)
    }

    // MARK: - Diff

    @Test("Two identical versions have nothing to report")
    func identicalVersionsDiffEmpty() {
        let store = DashboardVersionStore()
        let c = config(title: "Tokens", description: "d", tags: ["x"], panels: 2)
        #expect(store.diffVersions(version(1, c), version(2, c)).isEmpty)
    }

    @Test("A changed title is reported old-then-new, in that order")
    func titleDiffDirection() {
        let store = DashboardVersionStore()
        let diffs = store.diffVersions(version(1, config(title: "Old")), version(2, config(title: "New")))

        #expect(diffs.count == 1)
        #expect(diffs.first?.old == "Old")
        #expect(diffs.first?.new == "New", "reversing these would tell the user the change ran backwards")
    }

    @Test("Every field the screen knows how to show is reported when it changes")
    func allFieldsDiffed() {
        let store = DashboardVersionStore()
        let before = config(title: "A", description: "one", tags: ["x"], panels: 1,
                            from: "now-1h", refresh: .off)
        let after = config(title: "B", description: "two", tags: ["y", "z"], panels: 4,
                           from: "now-7d", refresh: .oneMinute)
        let diffs = store.diffVersions(version(1, before), version(2, after))

        #expect(diffs.count == 6, "title, description, panel count, time, refresh, tags")
        let olds = diffs.map(\.old)
        let news = diffs.map(\.new)
        #expect(olds.contains("A") && news.contains("B"))
        #expect(olds.contains("one") && news.contains("two"))
        #expect(olds.contains("1") && news.contains("4"))
        #expect(olds.contains("now-1h") && news.contains("now-7d"))
        #expect(news.contains("y, z"))
    }

    @Test("A description that was never set reads as a dash, not as empty")
    func missingDescriptionRendered() {
        let store = DashboardVersionStore()
        let diffs = store.diffVersions(
            version(1, config(description: nil)),
            version(2, config(description: "now it has one"))
        )
        #expect(diffs.count == 1)
        #expect(diffs.first?.old == "-")
        #expect(diffs.first?.new == "now it has one")
    }

    @Test("A panel swapped for another is not reported as a panel-count change")
    func sameCountDifferentPanels() {
        let store = DashboardVersionStore()
        var before = config(panels: 2)
        var after = before
        after.panels[0].title = "renamed"
        before.version = 1
        after.version = 1

        let diffs = store.diffVersions(version(1, before), version(2, after))
        // The store diffs the count, not the panels themselves. This pins that
        // it is what it is, so a screen reading "no changes" here is expected
        // rather than a regression someone re-discovers later.
        #expect(diffs.isEmpty)
    }

    @Test("Changing only the time range reports only the time range")
    func timeOnlyDiff() {
        let store = DashboardVersionStore()
        let diffs = store.diffVersions(
            version(1, config(from: "now-1h")),
            version(2, config(from: "now-30d"))
        )
        #expect(diffs.count == 1)
        #expect(diffs.first?.old == "now-1h")
        #expect(diffs.first?.new == "now-30d")
    }

    @Test("Tags are reported as a joined list, and clearing them is a change")
    func tagsDiff() {
        let store = DashboardVersionStore()
        let diffs = store.diffVersions(
            version(1, config(tags: ["prod", "cost"])),
            version(2, config(tags: []))
        )
        #expect(diffs.count == 1)
        #expect(diffs.first?.old == "prod, cost")
        #expect(diffs.first?.new == "")
    }
}

/// `VersionCompatibilityChecker` gates the whole query feature on the installed
/// toki being new enough, so a wrong answer here either nags a user who is up
/// to date or silently lets an incompatible CLI through.
///
/// Only the read half is covered. `checkOnLaunch()` and `recheckVersion()`
/// write the dismissal key into `UserDefaults.standard` — the live
/// `com.toki.monitor` domain under this test host — and open an `NSWindow`
/// modal, so they are left alone.
@MainActor
@Suite("toki version gate", .serialized)
struct TokiVersionGateTests {

    @Test("The required major version is a real requirement, not a placeholder")
    func requiredVersionIsSane() {
        #expect(requiredTokiMajorVersion >= 2)
    }

    @Test("The major version is read out of what `toki --version` actually prints")
    func parsesRealCLIOutput() async throws {
        // `toki --version` talks to no daemon and reads no user data. The point
        // of running the real binary is that the parser's only input is a
        // format that lives outside this repo: if toki ever stops printing
        // "toki X.Y.Z", the gate silently starts answering nil, which
        // checkOnLaunch reads as "toki is absent, stay quiet".
        let raw = try? await CLIProcessRunner.run(
            executable: TokiPath.resolved, arguments: ["--version"], timeout: 10
        )
        try #require(raw != nil, "toki is not installed on this machine; nothing to check")
        let text = String(data: raw!, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let major = await VersionCompatibilityChecker().installedTokiMajorVersion()
        try #require(major != nil, "the installed toki printed \(text.debugDescription), which the gate could not read")
        #expect(major! >= 1)

        // And it must be the number in that string, not something else.
        let expected = Int(text.replacingOccurrences(of: "toki ", with: "")
            .split(separator: ".").first.map(String.init) ?? "")
        #expect(major == expected)
    }

    @Test("A toki this build is happy with does not read as outdated")
    func installedTokiIsCompatible() async throws {
        let major = await VersionCompatibilityChecker().installedTokiMajorVersion()
        try #require(major != nil)
        // If this ever fails, the app on this machine is showing the
        // update-required modal at every launch — which is worth failing over.
        #expect(major! >= requiredTokiMajorVersion,
                "installed toki major \(major!) is below the required \(requiredTokiMajorVersion)")
    }
}
