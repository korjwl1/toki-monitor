import Testing
import Foundation
import SwiftUI
@testable import TokiMonitor

/// Two things that are only true if they are on the screen.
///
/// Contract Q4 says a panel whose ad hoc filter did not apply must show that,
/// and contract R7 says the legend is the series control. Both are claims
/// about pixels: a notice held in a struct nobody draws is the same as no
/// notice, which is exactly the state this work started from.
@Suite("Panel notices and legend, rendered")
@MainActor
struct PanelNoticeSnapshotTests {

    private let size = CGSize(width: 320, height: 220)

    private func panelRaster(filterNotices: [String],
                             theme: PanelSnapshotTheme) throws -> PanelRaster {
        let view = PanelContainerView(
            title: "Tokens",
            isEditing: false,
            state: .loaded,
            onDelete: {}, onEdit: {},
            filterNotices: filterNotices
        ) {
            Color.clear
        }
        return try #require(PanelSnapshotRenderer.raster(view, theme: theme, size: size))
    }

    // MARK: - The filter notice (T056)

    /// The threshold is low because the thing being measured is small: a badge
    /// in a title bar is a few hundred pixels of a 320×220 panel. What matters
    /// is that it is not zero — a notice that changes no pixel is the state
    /// this work started from, where the fact existed and nobody could see it.
    @Test("a panel the filter missed does not look like one it reached",
          arguments: PanelSnapshotTheme.allCases)
    func noticeChangesTheScreen(theme: PanelSnapshotTheme) throws {
        let quiet = try panelRaster(filterNotices: [], theme: theme)
        let noticed = try panelRaster(
            filterNotices: ["The filter was not applied: no metric selector was found."],
            theme: theme
        )
        #expect(PanelRaster.difference(quiet, noticed) > 0.002,
                "\(theme.rawValue): the notice is not visible on the panel")
    }

    // Contrast is NOT measured through `PanelContainerView` here, for the
    // reason the harness records: on macOS 26 the card is drawn with
    // `glassEffect`, which does not composite in an offscreen `cacheDisplay`,
    // so everything inside comes back washed out and the measurement would be
    // of the capture rather than of the design. The legend below is rendered
    // bare, and is measured.

    // MARK: - The legend (T057)

    private func legendRaster(hidden: Set<String>,
                              position: PanelDisplayOptions.LegendPosition = .bottom,
                              theme: PanelSnapshotTheme) throws -> PanelRaster {
        let view = PanelLegendView(
            entries: [.init(name: "opus", color: .blue),
                      .init(name: "sonnet", color: .green)],
            hidden: hidden,
            position: position,
            onToggle: { _ in }
        )
        return try #require(PanelSnapshotRenderer.raster(
            view, theme: theme, size: CGSize(width: 240, height: 40)
        ))
    }

    @Test("the legend draws its entries", arguments: PanelSnapshotTheme.allCases)
    func legendDrawsSomething(theme: PanelSnapshotTheme) throws {
        let raster = try legendRaster(hidden: [], theme: theme)
        #expect(raster.inkCoverage > 0.02, "\(theme.rawValue): the legend drew almost nothing")
    }

    /// A hidden series stays in the legend — it is the only way back — so it
    /// has to be distinguishable from a shown one without being invisible.
    @Test("a hidden entry looks different from a shown one",
          arguments: PanelSnapshotTheme.allCases)
    func hiddenEntryLooksDifferent(theme: PanelSnapshotTheme) throws {
        let shown = try legendRaster(hidden: [], theme: theme)
        let hidden = try legendRaster(hidden: ["opus"], theme: theme)
        #expect(PanelRaster.difference(shown, hidden) > 0.005,
                "\(theme.rawValue): hiding a series does not change the legend")
    }

    /// Contract R6: a legend must reach 3:1. The obvious way to mark a hidden
    /// entry — fade the row — puts it under that, which is why hidden is
    /// marked by a struck-through name and a hollow swatch instead.
    @Test("a hidden entry stays readable", arguments: PanelSnapshotTheme.allCases)
    func hiddenEntryStaysReadable(theme: PanelSnapshotTheme) throws {
        let hidden = try legendRaster(hidden: ["opus", "sonnet"], theme: theme)
        #expect(hidden.peakContrast >= 3.0,
                "\(theme.rawValue): the hidden entries fell below legend contrast")
    }

    @Test("the legend lays out down the side as well as along the bottom",
          arguments: PanelSnapshotTheme.allCases)
    func legendPositionsDiffer(theme: PanelSnapshotTheme) throws {
        let bottom = try legendRaster(hidden: [], position: .bottom, theme: theme)
        let right = try legendRaster(hidden: [], position: .right, theme: theme)
        #expect(PanelRaster.difference(bottom, right) > 0.005,
                "\(theme.rawValue): the legend position option changes nothing")
    }
}
