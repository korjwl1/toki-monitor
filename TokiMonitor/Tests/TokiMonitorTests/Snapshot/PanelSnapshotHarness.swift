import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - Panel snapshot matrix
//
// Panel type × state × theme, rendered for real through `NSHostingView` and
// asserted on the pixels. The point is not to catch a one-pixel shift — it is
// that nobody reviewing this work can see the screen, so "the five states look
// different" has to be something a machine can check.
//
// What is deliberately NOT here: `DashboardViewModel`. Its initializer calls
// `populateProviderOptions()`, which calls `saveDashboard()`, which writes the
// developer's real dashboard file. A test suite must not be able to destroy the
// data of the person running it. The two panel types that need one
// (`timeSeries`, `barChart`) therefore snapshot their status states through the
// same container with an inert content view — which is exactly what the
// container does with content in those states — and their `loaded` render is
// covered by the pure-function tests over series splitting and option mapping
// instead.

enum PanelSnapshotTheme: String, CaseIterable, Sendable {
    case light
    case dark

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
    /// The ground the artifact viewer paints behind the panel. Panels are
    /// translucent cards, so a snapshot with no ground under it measures
    /// contrast against nothing.
    var ground: Color { self == .dark ? Color(white: 0.11) : Color(white: 0.96) }
}

/// The state axis, flattened so a case can name itself in a filename.
enum PanelSnapshotState: String, CaseIterable, Sendable {
    case idle
    case loadingCold
    case loadingWithPrevious
    case loaded
    case emptyNoData
    case emptyHidden
    case failed

    var panelState: PanelState {
        switch self {
        case .idle: return .idle
        case .loadingCold: return .loading(hasPrevious: false)
        case .loadingWithPrevious: return .loading(hasPrevious: true)
        case .loaded: return .loaded
        case .emptyNoData: return .empty(.noDataInRange)
        case .emptyHidden: return .empty(.allSeriesHidden)
        case .failed: return .failed(reason: "connection refused (127.0.0.1:9494)")
        }
    }
}

struct PanelSnapshotCase: Hashable, Sendable {
    let panelType: PanelType
    let state: PanelSnapshotState
    let theme: PanelSnapshotTheme

    var name: String { "\(panelType.rawValue)-\(state.rawValue)-\(theme.rawValue)" }

    /// Whether this case renders the panel's real content.
    ///
    /// False only where the state draws the panel's own content AND that
    /// content needs a `DashboardViewModel` — see the note at the top of the
    /// file. Such a case still renders the container and its title; it just
    /// cannot make a claim about what the chart looks like, so the tests that
    /// assert about content skip it rather than passing on a stand-in.
    var usesRealContent: Bool {
        guard state == .loaded || state == .loadingWithPrevious else { return true }
        return PanelSnapshotMatrix.rendersContent.contains(panelType)
    }
}

// MARK: - Raster

/// A rendered panel, as pixels.
struct PanelRaster: Sendable {
    let width: Int
    let height: Int
    /// RGBA, row-major.
    let pixels: [UInt8]

    func rgb(x: Int, y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
    }

    /// WCAG relative luminance.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }

    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The panel's own background, sampled just inside the card.
    var background: (Double, Double, Double) { rgb(x: width / 2, y: 4) }

    /// Fraction of pixels that differ noticeably from the panel background —
    /// "is anything drawn here at all".
    var inkCoverage: Double {
        let bg = background
        var marked = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let p = rgb(x: x, y: y)
                if abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 0.08 { marked += 1 }
            }
        }
        return Double(marked) / Double((height / 2) * (width / 2))
    }

    /// The best contrast any drawn pixel reaches against the panel background.
    /// A screen whose best is below 4.5:1 has no readable body text on it.
    var peakContrast: Double {
        let bg = background
        var best = 1.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                best = max(best, PanelRaster.contrast(rgb(x: x, y: y), bg))
            }
        }
        return best
    }

    /// How many sampled pixels reach a given contrast against the background.
    func pixelsAbove(contrast target: Double) -> Int {
        let bg = background
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                if PanelRaster.contrast(rgb(x: x, y: y), bg) >= target { count += 1 }
            }
        }
        return count
    }

    /// Fraction of sampled pixels where two renders disagree.
    static func difference(_ a: PanelRaster, _ b: PanelRaster) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1 }
        var differing = 0
        var total = 0
        for y in stride(from: 0, to: a.height, by: 2) {
            for x in stride(from: 0, to: a.width, by: 2) {
                total += 1
                let p = a.rgb(x: x, y: y), q = b.rgb(x: x, y: y)
                if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 0.06 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }
}

// MARK: - Renderer

@MainActor
enum PanelSnapshotRenderer {

    /// A panel roughly the size of a default grid cell — and small enough that
    /// anything which needs a scrollbar has to keep it inside itself.
    static let panelSize = CGSize(width: 320, height: 220)

    static func render(_ snapshotCase: PanelSnapshotCase,
                       size: CGSize = panelSize) -> PanelRaster? {
        raster(panelView(for: snapshotCase), theme: snapshotCase.theme, size: size)
    }

    @MainActor @ViewBuilder
    static func panelView(for snapshotCase: PanelSnapshotCase) -> some View {
        PanelContainerView(
            title: snapshotCase.panelType.displayName,
            isEditing: false,
            state: snapshotCase.state.panelState,
            onDelete: {},
            onEdit: {},
            onRetry: {}
        ) {
            content(for: snapshotCase.panelType)
        }
    }

    /// The real render for every panel type that does not need a view model.
    @MainActor @ViewBuilder
    static func content(for type: PanelType) -> some View {
        switch type {
        case .stat:
            StatPanelView(panel: PanelSnapshotFixtures.panel(type),
                          data: nil, frames: PanelSnapshotFixtures.frames)
        case .gauge:
            GaugePanelView(panel: PanelSnapshotFixtures.gaugePanel,
                           data: nil, frames: PanelSnapshotFixtures.frames)
        case .table:
            TablePanelView(panel: PanelSnapshotFixtures.panel(type),
                           data: nil, frames: PanelSnapshotFixtures.frames)
        case .pieChart:
            PieChartView(entries: [.init(label: "opus", value: 62),
                                   .init(label: "sonnet", value: 38)], colors: nil)
        case .stateTimeline:
            StateTimelinePanelView(panel: PanelSnapshotFixtures.panel(type),
                                   frames: PanelSnapshotFixtures.frames,
                                   dateFormat: .dateTime.hour().minute())
        case .unknown:
            UnknownPanelView(panel: PanelSnapshotFixtures.panel(.stat))
        case .timeSeries, .barChart, .rowPanel:
            // See the note at the top of the file: constructing these needs a
            // `DashboardViewModel`, and constructing one of those writes to the
            // user's saved dashboard.
            Color.clear
        }
    }

    static func raster<V: View>(_ view: V, theme: PanelSnapshotTheme, size: CGSize) -> PanelRaster? {
        let root = ZStack {
            theme.ground
            view.padding(DS.sm)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, theme.colorScheme)

        // Hosted in a real window with the appearance set on it. Text that
        // names no colour resolves the label colour from the view's window,
        // not from the SwiftUI colour scheme — so a hosting view floating
        // outside any window draws dark-mode labels in black, and every
        // contrast measurement here would be measuring that instead.
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = theme.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        // Text that does not name a colour resolves it from the CURRENT
        // DRAWING appearance, not from the SwiftUI environment — so an
        // offscreen capture without this draws dark-mode labels in black and
        // every contrast measurement below becomes a measurement of a bug in
        // the harness.
        if let appearance = theme.appearance {
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
        } else {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        guard let cg = rep.cgImage else { return nil }

        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return PanelRaster(width: width, height: height, pixels: pixels)
    }
}

// MARK: - Fixtures

@MainActor
enum PanelSnapshotFixtures {

    static func panel(_ type: PanelType, metric: PanelMetric = .totalTokens) -> PanelConfig {
        PanelConfig(title: type.displayName, panelType: type, metric: metric,
                    gridPosition: GridPosition(column: 0, row: 0, width: 6, height: 4))
    }

    /// A gauge with both ends of its scale and two threshold bands — the state
    /// the contract describes, not the degenerate one.
    static var gaugePanel: PanelConfig {
        var config = panel(.gauge)
        config.options.gaugeMin = 0
        config.options.gaugeMax = 100_000
        config.options.thresholds = [
            ThresholdStep(value: 50_000, color: .orange),
            ThresholdStep(value: 80_000, color: .red),
        ]
        return config
    }

    static var frames: FrameSet {
        FrameSet(frames: [frame("opus", tokens: [12_000, 31_000, 24_000]),
                          frame("sonnet", tokens: [4_000, 9_500, 7_200])])
    }

    static func frame(_ model: String, tokens: [Double?]) -> Frame {
        let labels = ["model": model]
        return Frame(refId: "A", fields: [
            Field(name: "time", labels: labels,
                  values: .time(tokens.indices.map {
                      Date(timeIntervalSince1970: 1_750_000_000 + Double($0) * 3600)
                  })),
            Field(name: "total_tokens", labels: labels, values: .number(tokens)),
            Field(name: "cost_usd", labels: labels,
                  values: .number(tokens.map { $0.map { $0 / 1000 } })),
        ])
    }
}

// MARK: - Matrix

enum PanelSnapshotMatrix {

    /// Row panels are headers, not data panels — they have no five states to
    /// draw and `CustomDashboardView` routes them before the container.
    static let panelTypes: [PanelType] = [
        .stat, .timeSeries, .barChart, .pieChart, .table, .gauge, .stateTimeline,
    ]

    /// The cases whose render is the panel's own, all the way down.
    static var renderable: [PanelSnapshotCase] { all.filter(\.usesRealContent) }

    static var all: [PanelSnapshotCase] {
        panelTypes.flatMap { type in
            PanelSnapshotState.allCases.flatMap { state in
                PanelSnapshotTheme.allCases.map {
                    PanelSnapshotCase(panelType: type, state: state, theme: $0)
                }
            }
        }
    }

    /// The types whose `loaded` render is real in this harness.
    static let rendersContent: Set<PanelType> = [.stat, .pieChart, .table, .gauge, .stateTimeline]
}

@Suite("Panel snapshot matrix")
@MainActor
struct PanelSnapshotMatrixTests {

    @Test("the matrix covers every panel type in every state in both themes")
    func matrixIsComplete() {
        let cases = PanelSnapshotMatrix.all
        #expect(cases.count == 7 * 7 * 2)
        #expect(Set(cases.map(\.name)).count == cases.count, "case names must be unique")
        // The screens the complaint was about have to be in the list.
        #expect(cases.contains { $0.panelType == .gauge && $0.state == .loaded && $0.theme == .dark })
        #expect(cases.contains { $0.panelType == .table && $0.state == .emptyNoData && $0.theme == .light })
    }
}
