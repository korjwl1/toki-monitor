import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - The dashboard at its smallest window
//
// 계약 R6 / FR-059: at the 800×600 minimum the dashboard must not scroll or
// clip sideways, and wide content — a table, a state timeline — must scroll
// INSIDE its own container instead of pushing the page.
//
// The grid cannot scroll horizontally: `CustomDashboardView` wraps it in a
// vertical `ScrollView` only. So the failure mode is not a scrollbar appearing,
// it is a panel PAINTING OUTSIDE the cell it was given — SwiftUI does not clip
// by default, and a view with a hard minimum width larger than its frame simply
// draws over its neighbours.
//
// That is what is measured here, and it is measured by rendering: the panel is
// given its own minimum grid width on a wider canvas, and any ink outside the
// cell is an overflow. `fittingSize` was the obvious tool and the wrong one —
// it returns the IDEAL width (a title unwrapped onto one line), not the width
// below which the layout breaks, so it flags panels that compress perfectly
// well and would have made this suite noise.

@Suite("Minimum window size", .serialized)
@MainActor
struct MinimumWindowTests {

    /// The window's own minimum, and what is left for the grid after it.
    ///
    /// 800 wide, less the sidebar at its minimum (180) and the grid's padding
    /// on both sides. Everything below is measured against panels laid out in
    /// what remains.
    static let windowWidth: CGFloat = 800
    static let sidebarMinimum: CGFloat = 180

    static var gridWidth: CGFloat {
        windowWidth - sidebarMinimum - DS.Dashboard.gridPadding * 2
    }

    /// The narrowest cell the editor will let a panel of this type occupy, in
    /// points, in the smallest window. `PanelType.minWidth` is in columns and
    /// is what `PanelEdgeResize` clamps to, so this is the real floor rather
    /// than a number picked for the test.
    static func narrowestCell(for type: PanelType) -> CGFloat {
        DashboardGridLayout.frame(
            for: GridPosition(column: 0, row: 0, width: type.minWidth, height: 4),
            in: gridWidth
        ).width
    }

    /// How much ink a view paints outside the cell it was given.
    ///
    /// The panel is placed on a canvas wide enough to show an overflow in
    /// either direction — SwiftUI centres content it cannot compress, so a
    /// panel that is too wide spills both ways.
    private func overflowInk(of view: some View, cellWidth: CGFloat,
                             height: CGFloat = 160) -> Int {
        let gutter: CGFloat = 90
        let canvas = CGSize(width: gutter * 2 + cellWidth + DS.sm * 2,
                            height: height + DS.sm * 2)
        let root = ZStack(alignment: .topLeading) {
            Color.clear
            view
                .frame(width: cellWidth, height: height)
                .padding(.leading, gutter)
        }
        guard let raster = PanelSnapshotRenderer.raster(root, theme: .light,
                                                        size: canvas) else {
            return Int.max
        }
        // `raster` pads its subject by `DS.sm` and paints the theme ground
        // behind it, so the cell starts one padding plus one gutter in.
        let scale = CGFloat(raster.width) / canvas.width
        let cellStart = Int((DS.sm + gutter) * scale)
        let cellEnd = Int((DS.sm + gutter + cellWidth) * scale)
        let ground = raster.rgb(x: 2, y: 2)

        var outside = 0
        for y in stride(from: 0, to: raster.height, by: 2) {
            for x in stride(from: 0, to: raster.width, by: 2) {
                // Two pixels of slack each side: antialiasing on the card's
                // rounded border lands a hair outside its own rect.
                guard x < cellStart - 4 || x > cellEnd + 4 else { continue }
                let pixel = raster.rgb(x: x, y: y)
                if abs(pixel.0 - ground.0) + abs(pixel.1 - ground.1)
                    + abs(pixel.2 - ground.2) > 0.08 {
                    outside += 1
                }
            }
        }
        return outside
    }

    @Test("no panel type paints outside the narrowest cell it can be given",
          arguments: PanelSnapshotMatrix.panelTypes)
    func panelsFitTheirNarrowestCell(type: PanelType) {
        let cell = Self.narrowestCell(for: type)
        let ink = overflowInk(
            of: PanelSnapshotRenderer.panelView(
                for: PanelSnapshotCase(panelType: type, state: .loaded, theme: .light)
            ),
            cellWidth: cell
        )
        #expect(ink == 0,
                "\(type.rawValue) paints \(ink) sampled pixels outside a \(Int(cell))pt cell — that ink lands on the panel beside it")
    }

    @Test("every state fits the narrowest cell too", arguments: PanelSnapshotState.allCases)
    func statesFitTheNarrowestCell(state: PanelSnapshotState) {
        // The status views carry the longest strings on the dashboard: the
        // empty-range explanation is two sentences in a box that can be 120pt
        // tall and 140pt wide.
        let cell = Self.narrowestCell(for: .timeSeries)
        let ink = overflowInk(
            of: PanelSnapshotRenderer.panelView(
                for: PanelSnapshotCase(panelType: .timeSeries, state: state, theme: .light)
            ),
            cellWidth: cell, height: 120
        )
        #expect(ink == 0,
                "\(state.rawValue) paints \(ink) sampled pixels outside a \(Int(cell))pt cell")
    }

    @Test("a table too wide for its panel scrolls inside itself")
    func wideTableScrollsInside() {
        // Names far longer than any real model id, so the table's natural width
        // is several times the cell's.
        let long = String(repeating: "claude-opus-4-1-20250805-extended-", count: 3)
        let frames = FrameSet(frames: (0..<6).map { index in
            PanelSnapshotFixtures.frame("\(long)\(index)", tokens: [10_000, 20_000])
        })
        let ink = overflowInk(
            of: TablePanelView(panel: PanelSnapshotFixtures.panel(.table),
                               data: nil, frames: frames),
            cellWidth: Self.narrowestCell(for: .table)
        )
        #expect(ink == 0,
                "the table spilled \(ink) sampled pixels onto the page instead of scrolling in its own container")
    }

    /// The funnels are extra ink in a header that was already the widest thing
    /// in the panel. They have to truncate the column name rather than widen
    /// the column — the whole point of R6 is that no panel pushes the page.
    @Test("a filterable table keeps its funnels inside the narrowest cell")
    func filterableTableFitsTheNarrowestCell() {
        var panel = PanelSnapshotFixtures.panel(.table)
        panel.fieldConfig = FieldConfigSource(
            defaults: FieldDisplayConfig(filterable: true)
        )
        let ink = overflowInk(
            of: TablePanelView(panel: panel, data: nil,
                               frames: PanelSnapshotFixtures.frames,
                               onSetFilter: { _, _ in }),
            cellWidth: Self.narrowestCell(for: .table)
        )
        #expect(ink == 0,
                "the column filters spilled \(ink) sampled pixels onto the page")
    }

    /// A hidden slice leaves its legend entry behind — struck through, with a
    /// hollow swatch — which is wider than the entry was before, in the panel
    /// type whose legend is already pinned to 140pt.
    @Test("a pie with a hidden slice keeps its legend inside the cell")
    func pieWithHiddenSliceFits() {
        let ink = overflowInk(
            of: PieChartView(
                entries: [.init(label: "claude-opus-4-1-20250805", value: 62),
                          .init(label: "claude-sonnet-4-5-20250929", value: 38)],
                colors: nil, hidden: ["claude-opus-4-1-20250805"], onToggle: { _ in }
            ),
            cellWidth: Self.narrowestCell(for: .pieChart)
        )
        #expect(ink == 0, "the pie legend spilled \(ink) sampled pixels")
    }

    @Test("a state timeline over a long window scrolls inside itself")
    func wideTimelineScrollsInside() {
        let frames = FrameSet(frames: (0..<4).map { index in
            PanelSnapshotFixtures.frame("series-\(index)",
                                        tokens: Array(repeating: 5_000, count: 200))
        })
        let ink = overflowInk(
            of: StateTimelinePanelView(panel: PanelSnapshotFixtures.panel(.stateTimeline),
                                       frames: frames,
                                       dateFormat: .dateTime.hour().minute()),
            cellWidth: Self.narrowestCell(for: .stateTimeline)
        )
        #expect(ink == 0, "the state timeline spilled \(ink) sampled pixels")
    }

    @Test("a long title truncates rather than widening the panel")
    func longTitlesDoNotWiden() {
        let ink = overflowInk(
            of: PanelContainerView(
                title: String(repeating: "Tokens by model and project ", count: 4),
                isEditing: false,
                state: .loaded,
                panelType: .stat,
                valueSummary: "1.2M",
                onDelete: {}, onEdit: {}
            ) { Color.clear },
            cellWidth: Self.narrowestCell(for: .stat)
        )
        #expect(ink == 0, "a long title spilled \(ink) sampled pixels past the panel")
    }

    @Test("the grid's own arithmetic never produces a panel wider than the grid")
    func gridNeverOverflows() {
        // The layout is what places the panels; if it can compute a frame that
        // runs past the container, no amount of compressible content saves the
        // page.
        for columns in 1...DashboardGridLayout.columnCount {
            let frame = DashboardGridLayout.frame(
                for: GridPosition(column: DashboardGridLayout.columnCount - columns,
                                  row: 0, width: columns, height: 4),
                in: Self.gridWidth
            )
            #expect(frame.maxX <= Self.gridWidth + 0.001,
                    "a \(columns)-column panel at the right edge runs \(frame.maxX - Self.gridWidth)pt past the grid")
        }
    }
}
