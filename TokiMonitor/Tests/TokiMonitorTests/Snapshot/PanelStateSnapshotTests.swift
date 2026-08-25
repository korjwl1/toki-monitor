import Testing
import Foundation
import SwiftUI
@testable import TokiMonitor

/// What the pixels actually say.
///
/// These render every panel type in every state in both themes through
/// `NSHostingView` and assert on the result. They are not golden-image
/// comparisons — a recorded PNG would fail on every OS point release and teach
/// everyone to re-record it. They assert the properties the contract states:
/// something is drawn, the states differ from each other, both themes work, and
/// the text on screen is readable.
@Suite("Panel state snapshots")
@MainActor
struct PanelStateSnapshotTests {

    private func render(_ type: PanelType, _ state: PanelSnapshotState,
                        _ theme: PanelSnapshotTheme) throws -> PanelRaster {
        let snapshotCase = PanelSnapshotCase(panelType: type, state: state, theme: theme)
        return try #require(PanelSnapshotRenderer.render(snapshotCase),
                            "failed to rasterize \(snapshotCase.name)")
    }

    // MARK: - Something is drawn

    /// The original complaint, stated as a test: no state may render as a blank
    /// rectangle. `Spacer()` scores zero here.
    @Test("no panel in any state renders blank", arguments: PanelSnapshotMatrix.renderable)
    func nothingRendersBlank(snapshotCase: PanelSnapshotCase) throws {
        let raster = try #require(PanelSnapshotRenderer.render(snapshotCase),
                                  "failed to rasterize \(snapshotCase.name)")
        // The title bar and divider alone clear this; a panel body that draws
        // nothing but still has a title would pass, which is why the state
        // difference tests below carry the real weight.
        #expect(raster.inkCoverage > 0.01, "\(snapshotCase.name) drew almost nothing")
    }

    // MARK: - The states differ

    @Test("empty and failed do not look alike", arguments: PanelSnapshotMatrix.panelTypes,
          PanelSnapshotTheme.allCases)
    func emptyDiffersFromFailed(type: PanelType, theme: PanelSnapshotTheme) throws {
        let empty = try render(type, .emptyNoData, theme)
        let failed = try render(type, .failed, theme)
        #expect(PanelRaster.difference(empty, failed) > 0.02,
                "\(type.rawValue)/\(theme.rawValue): empty and failed render the same")
    }

    @Test("idle, empty and failed are three different screens",
          arguments: PanelSnapshotTheme.allCases)
    func threeScreensAreThree(theme: PanelSnapshotTheme) throws {
        let idle = try render(.timeSeries, .idle, theme)
        let empty = try render(.timeSeries, .emptyNoData, theme)
        let failed = try render(.timeSeries, .failed, theme)
        #expect(PanelRaster.difference(idle, empty) > 0.02)
        #expect(PanelRaster.difference(idle, failed) > 0.02)
        #expect(PanelRaster.difference(empty, failed) > 0.02)
    }

    @Test("the two reasons a panel can be empty read differently",
          arguments: PanelSnapshotTheme.allCases)
    func emptyReasonsRenderDifferently(theme: PanelSnapshotTheme) throws {
        let noData = try render(.barChart, .emptyNoData, theme)
        let hidden = try render(.barChart, .emptyHidden, theme)
        #expect(PanelRaster.difference(noData, hidden) > 0.02)
    }

    // MARK: - Loading holds the previous result

    /// Contract R3: loading keeps the previous result, dimmed. If the held-over
    /// render were identical to `loaded` the dimming is missing; if it were
    /// identical to the cold load the result was thrown away.
    @Test("a refresh dims the previous result instead of clearing it",
          arguments: PanelSnapshotMatrix.rendersContent.sorted { $0.rawValue < $1.rawValue })
    func refreshDimsRatherThanClears(type: PanelType) throws {
        let loaded = try render(type, .loaded, .light)
        let refreshing = try render(type, .loadingWithPrevious, .light)
        let cold = try render(type, .loadingCold, .light)

        let dimmed = PanelRaster.difference(loaded, refreshing)
        let cleared = PanelRaster.difference(loaded, cold)

        #expect(dimmed > 0.002,
                "\(type.rawValue): a refresh looks exactly like a finished load")
        #expect(PanelRaster.difference(refreshing, cold) > 0.005,
                "\(type.rawValue): a refresh threw the previous result away")
        // The load-bearing comparison: dimmed, not replaced. The held-over
        // frame resembles the finished result far more than a cold load does.
        #expect(dimmed < cleared,
                "\(type.rawValue): the held-over frame is not the previous result")
    }

    // MARK: - Both themes

    @Test("light and dark are actually different renders",
          arguments: PanelSnapshotMatrix.panelTypes)
    func themesDiffer(type: PanelType) throws {
        let light = try render(type, .failed, .light)
        let dark = try render(type, .failed, .dark)
        #expect(PanelRaster.difference(light, dark) > 0.5,
                "\(type.rawValue) renders the same in both appearances")
    }

    /// Contract R6, measured on the status screen over the dashboard ground.
    ///
    /// Deliberately NOT measured through `PanelContainerView`: on macOS 26 the
    /// card is drawn with `glassEffect`, and a glass layer does not composite
    /// in an offscreen `cacheDisplay` — everything inside it comes back washed
    /// out. Measuring through it would measure the capture rather than the
    /// design. The card is a translucent material either way: it shifts the
    /// ground a little, it does not change the text colour, which is what this
    /// asserts.
    @Test("status text stays readable in both themes",
          arguments: PanelSnapshotState.allCases, PanelSnapshotTheme.allCases)
    func statusTextIsReadable(state: PanelSnapshotState, theme: PanelSnapshotTheme) throws {
        let raster = try #require(PanelSnapshotRenderer.raster(
            PanelStatusView(state: state.panelState, onRetry: {}),
            theme: theme, size: PanelSnapshotRenderer.panelSize
        ))
        let ratio = String(format: "%.1f:1", raster.peakContrast)
        #expect(raster.peakContrast >= 4.5,
                "\(state.rawValue)/\(theme.rawValue): best text contrast is \(ratio)")
        // Not one stray antialiased pixel: a readable line of type.
        #expect(raster.pixelsAbove(contrast: 4.5) > 20,
                "\(state.rawValue)/\(theme.rawValue): almost nothing reaches 4.5:1")
    }

    // MARK: - Content states

    /// A gauge that is a big number and a gauge that is a dial differ by more
    /// than a rounding error. This is the test that would have failed against
    /// the shipping implementation.
    @Test("the gauge draws an arc, not just a number",
          arguments: PanelSnapshotTheme.allCases)
    func gaugeDrawsAnArc(theme: PanelSnapshotTheme) throws {
        let gauge = try render(.gauge, .loaded, theme)
        let stat = try render(.stat, .loaded, theme)
        #expect(PanelRaster.difference(gauge, stat) > 0.05,
                "gauge and stat render the same — the gauge is still large text")
        // A dial covers a good part of the panel; a line of text does not.
        #expect(gauge.inkCoverage > stat.inkCoverage,
                "the gauge covers no more of the panel than a stat card does")
    }

    /// Contract R6: a wide table scrolls inside its own container. A table that
    /// pushed its panel wider would render outside the card and change the
    /// pixels along the panel's right edge.
    @Test("a wide table stays inside its panel", arguments: PanelSnapshotTheme.allCases)
    func wideTableStaysInside(theme: PanelSnapshotTheme) throws {
        let table = try render(.table, .loaded, theme)
        let empty = try render(.table, .emptyNoData, theme)
        // The rightmost column of pixels is the dashboard ground outside the
        // card. It must be identical whether or not the table has wide content.
        var differing = 0
        for y in stride(from: 0, to: table.height, by: 2) {
            let a = table.rgb(x: table.width - 1, y: y)
            let b = empty.rgb(x: empty.width - 1, y: y)
            if abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > 0.06 { differing += 1 }
        }
        #expect(differing == 0, "\(theme.rawValue): table content reached past the panel edge")
    }
}
