import Testing
import SwiftUI
import Foundation
@testable import TokiMonitor

/// The sync settings section, rendered.
///
/// It shipped with light/dark and VoiceOver argued rather than shown — the
/// section uses semantic colours and standard focusable controls, which is a
/// reason to expect it works, not evidence that it does. These render it for
/// real, in both appearances, through the same harness the panel snapshots use
/// (hosted in a window with the appearance set, because a hosting view outside
/// one draws dark-mode labels in black and every measurement would be of that).
///
/// The controller is injected. Reaching `MonitorSyncController.shared` here
/// would touch `UserDefaults.standard`, which under this test host is the live
/// `com.toki.monitor` domain holding the user's real dashboards.
@Suite("The sync settings section renders in both appearances")
@MainActor
struct MonitorSyncSectionSnapshotTests {

    private static let size = CGSize(width: 520, height: 260)

    private func controller() -> MonitorSyncController {
        MonitorSyncController(
            engine: MonitorSyncEngine(
                transport: MonitorSettingsClient(),
                store: DashboardConfigStore(defaults: ScratchDefaults()),
                defaults: ScratchDefaults()
            ),
            settings: { nil }
        )
    }

    private func section() -> some View {
        Form { MonitorSyncSettingsSection(controller: controller()) }
    }

    @Test("it draws something in both appearances", arguments: PanelSnapshotTheme.allCases)
    func drawsInBothThemes(theme: PanelSnapshotTheme) throws {
        let raster = try #require(
            PanelSnapshotRenderer.raster(section(), theme: theme, size: Self.size),
            "\(theme.rawValue) produced no raster"
        )
        #expect(raster.inkCoverage > 0.01, "\(theme.rawValue) drew almost nothing")
    }

    /// The failure this catches is a colour that only works in one appearance:
    /// text hardcoded dark renders on a dark ground and the section becomes
    /// unreadable without anything erroring.
    @Test("the two appearances are genuinely different renders")
    func themesDiffer() throws {
        let light = try #require(PanelSnapshotRenderer.raster(section(), theme: .light, size: Self.size))
        let dark = try #require(PanelSnapshotRenderer.raster(section(), theme: .dark, size: Self.size))
        #expect(PanelRaster.difference(light, dark) > 0.02,
                "light and dark rendered the same — a hardcoded colour would look like this")
    }

    /// The disclosure is the one string that must not be reachable only from a
    /// help page: it is where the user learns their project names leave the
    /// machine. It is shown under the toggle AND used as the accessibility
    /// hint, so a VoiceOver user meets it at the same moment a sighted one does.
    @Test("the disclosure names what leaves the computer")
    func disclosureIsExplicit() {
        let text = MonitorSyncController.disclosure
        #expect(!text.isEmpty)
        // Both languages, whichever the suite runs in.
        let namesQueryStrings = text.contains("질의 문자열") || text.contains("query")
        let namesLeaving = text.contains("떠납니다") || text.contains("leave this computer")
        let excludesUsage = text.contains("사용량") || text.contains("usage")
        #expect(namesQueryStrings, "must say query strings go up as written")
        #expect(namesLeaving, "must say the names leave this machine")
        #expect(excludesUsage, "must say usage figures do not")
    }
}
