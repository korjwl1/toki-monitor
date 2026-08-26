import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - Plan-fit snapshot matrix
//
// The entry point the snapshot phase will render through. It fixes the three
// axes now, while the shape of the data is still being decided, so that the
// case list cannot quietly shrink to the states that happen to look good.
//
// The axis that matters most is `dataSufficiency`. Window history is new: the
// whole recorded history at measurement time was 21 rows, so "not enough to
// judge" is not an edge case — it is what every existing user opens the page
// to. A matrix carrying only the `.sufficient` column would leave the most
// common screen in the product unverified.
//
// The renderer lives at the foot of the file. It draws `PlanFitContent`, which
// is a pure function of a `PlanFitModel` and the one binding — no daemon, no
// network, no clock — at exactly the 800pt window minimum, because rendering
// wider would hide the overflow the layout claims are about.

/// How much finalized history the account has.
enum PlanFitDataSufficiency: String, CaseIterable, Sendable {
    /// No window rows at all — day one, or the daemon was never polling.
    case noRows
    /// A few days. Facts are showable; trends and verdicts are not.
    case fewDays
    /// Real history, still short of the 28-day gate (contract V2).
    case underLookback
    /// Past the gate, with an active-use sample worth reading.
    case sufficient
}

/// How many segments the page has to lay out at once.
enum PlanFitSegmentCount: Int, CaseIterable, Sendable {
    case one = 1
    case four = 4
    case eight = 8
}

enum PlanFitSnapshotTheme: String, CaseIterable, Sendable {
    case light
    case dark
}

struct PlanFitSnapshotCase: Hashable, Sendable {
    let sufficiency: PlanFitDataSufficiency
    let segments: PlanFitSegmentCount
    let theme: PlanFitSnapshotTheme

    /// Stable file-safe identity for the recorded image.
    var name: String { "\(sufficiency.rawValue)-\(segments.rawValue)seg-\(theme.rawValue)" }
}

enum PlanFitSnapshotMatrix {

    static let nowMs: Int64 = WindowFixtures.nowMs

    static var all: [PlanFitSnapshotCase] {
        PlanFitDataSufficiency.allCases.flatMap { sufficiency in
            PlanFitSegmentCount.allCases.flatMap { segments in
                PlanFitSnapshotTheme.allCases.map { theme in
                    PlanFitSnapshotCase(sufficiency: sufficiency, segments: segments, theme: theme)
                }
            }
        }
    }

    /// The window rows a case renders from.
    ///
    /// Each extra segment is a distinct limit id, never a distinct tier: tiers
    /// are what segments must never blend, so a fixture that grew segment count
    /// by inventing tiers would make the layout test double as a wrong claim
    /// about the statistics.
    static func rows(for snapshotCase: PlanFitSnapshotCase) -> [(provider: String, row: WindowRow)] {
        let span: Double
        switch snapshotCase.sufficiency {
        case .noRows: return []
        case .fewDays: span = 3
        case .underLookback: span = 18
        case .sufficient: span = 27
        }

        let limitIds = ["five_hour", "seven_day", "seven_day_sonnet", "weekly_fable",
                        "codex", "five_hour_alt", "seven_day_opus", "weekly_haiku"]
        let count = snapshotCase.segments.rawValue
        var rows: [(provider: String, row: WindowRow)] = []
        for index in 0..<count {
            let limitId = limitIds[index]
            let windows = max(Int(span) * 2, 2)
            for w in 0..<windows {
                let offset = span * Double(w) / Double(max(windows - 1, 1))
                let maxed = index == 0 && w % 4 == 0
                rows.append(WindowFixtures.window(
                    kind: "session",
                    limitId: limitId,
                    endOffsetDays: offset,
                    peakPct: maxed ? 100 : Double(30 + (index * 7 + w * 3) % 50),
                    activeMs: w % 3 == 0 ? 0 : 90 * 60_000,
                    maxedOut: maxed,
                    timeLeftFractionAtExhaustion: maxed ? 0.6 : nil,
                    nowMs: nowMs
                ))
            }
        }
        return rows
    }
}

// `@MainActor` for the same reason as `WindowStatsActiveUseTests`: advice
// wording goes through the main-actor-isolated localization table.
@Suite("Plan-fit snapshot matrix")
@MainActor
struct PlanFitSnapshotHarnessTests {

    /// 4 sufficiency states × 3 segment counts × 2 themes.
    @Test("the matrix covers every combination")
    func matrixCoversEveryCombination() {
        let cases = PlanFitSnapshotMatrix.all
        #expect(cases.count == 24)
        #expect(Set(cases.map(\.name)).count == 24, "case names must be unique per combination")
        // The screen most users will actually see has to be in the list.
        #expect(cases.contains {
            $0.sufficiency == .underLookback && $0.segments == .one && $0.theme == .light
        })
    }

    @Test("each case produces the data it advertises")
    func casesProduceTheirData() {
        for snapshotCase in PlanFitSnapshotMatrix.all {
            let rows = PlanFitSnapshotMatrix.rows(for: snapshotCase)
            let segments = WindowStats.segments(rows: rows, nowMs: PlanFitSnapshotMatrix.nowMs)
            if snapshotCase.sufficiency == .noRows {
                #expect(rows.isEmpty, "\(snapshotCase.name)")
                #expect(segments.isEmpty, "\(snapshotCase.name)")
            } else {
                #expect(segments.count == snapshotCase.segments.rawValue, "\(snapshotCase.name)")
            }
        }
    }

    /// Below the 28-day gate no segment may recommend paying less. The
    /// snapshot phase renders these cases specifically to show what "too early
    /// to judge" looks like, so the fixture must actually be too early —
    /// otherwise the recorded image pins the wrong screen.
    @Test("short-history cases never recommend a downgrade")
    func shortHistoryNeverDowngrades() {
        for sufficiency in [PlanFitDataSufficiency.fewDays, .underLookback] {
            let snapshotCase = PlanFitSnapshotCase(sufficiency: sufficiency, segments: .one, theme: .light)
            let rows = PlanFitSnapshotMatrix.rows(for: snapshotCase)
            for segment in WindowStats.segments(rows: rows, nowMs: PlanFitSnapshotMatrix.nowMs) {
                if case .downgrade = segment.advice {
                    Issue.record("\(snapshotCase.name) recommends paying less on \(Int(segment.observedDays))d of history")
                }
            }
        }
    }
}

// MARK: - Rendering

extension PlanFitSnapshotTheme {
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
    /// The window ground under the page. A page whose own surfaces are
    /// translucent has no measurable contrast without one.
    var ground: Color { self == .dark ? Color(white: 0.11) : Color(white: 0.96) }
}

@MainActor
enum PlanFitSnapshotRenderer {

    /// The window minimum (`DashboardWindow.swift`), less the sidebar the page
    /// sits beside. Rendering wider would hide exactly the overflow FR-056 is
    /// about, so this is the width every layout claim is made at.
    static let width: CGFloat = 800
    /// Tall enough to hold the lede and the first sections in view. The page
    /// scrolls; the assertions are about what a reader meets on arrival.
    static let height: CGFloat = 1200

    static func model(for snapshotCase: PlanFitSnapshotCase, unit: PeriodUnit = .weekly) -> PlanFitModel {
        PlanFitModelBuilder.build(
            rows: PlanFitSnapshotMatrix.rows(for: snapshotCase),
            unit: unit,
            nowMs: PlanFitSnapshotMatrix.nowMs
        )
    }

    static func render(
        _ snapshotCase: PlanFitSnapshotCase,
        unit: PeriodUnit = .weekly,
        size: CGSize = CGSize(width: width, height: height)
    ) -> PanelRaster? {
        raster(
            PlanFitContent(model: model(for: snapshotCase, unit: unit), unit: .constant(unit)),
            theme: snapshotCase.theme,
            size: size
        )
    }

    /// Hosted in a real window with the appearance set on it, and captured
    /// inside `performAsCurrentDrawingAppearance`. Both are load-bearing for
    /// the same reason as in `PanelSnapshotHarness`: text that names no colour
    /// resolves the label colour from the window and from the current drawing
    /// appearance, so a capture without them draws dark-mode labels in black
    /// and every contrast number below becomes a measurement of the harness.
    ///
    /// Unlike the panel renderer this adds no padding of its own — the claim
    /// being tested is that the page's own layout holds at exactly 800pt.
    static func raster<V: View>(_ view: V, theme: PlanFitSnapshotTheme, size: CGSize) -> PanelRaster? {
        let root = ZStack {
            theme.ground
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, theme.colorScheme)

        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = theme.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        if let appearance = theme.appearance {
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
        } else {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        guard let cg = rep.cgImage else { return nil }

        let pixelWidth = cg.width, pixelHeight = cg.height
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let ctx = CGContext(
            data: &pixels, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return PanelRaster(width: pixelWidth, height: pixelHeight, pixels: pixels)
    }
}

extension PanelRaster {

    /// The first row where two renders of the same page differ.
    ///
    /// Used to locate a block vertically without asking the view where it drew
    /// itself. Render the page with a block and without it: everything ABOVE
    /// the block is pixel-identical, so the first differing row is the block's
    /// top edge. Removing a block shifts what follows it, so only the FIRST
    /// differing row means anything — the last one is always the page bottom.
    static func firstDifferingRow(_ a: PanelRaster, _ b: PanelRaster) -> Int? {
        guard a.width == b.width, a.height == b.height else { return 0 }
        for y in 0..<a.height {
            for x in stride(from: 0, to: a.width, by: 2) {
                let p = a.rgb(x: x, y: y), q = b.rgb(x: x, y: y)
                if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 0.04 { return y }
            }
        }
        return nil
    }

    /// The window ground, sampled from a corner the page never paints into.
    var pageGround: (Double, Double, Double) { rgb(x: 2, y: 2) }

    /// Ink measured against the window ground rather than against the panel
    /// background `background` samples — this page has no card at its top edge.
    var pageInkCoverage: Double {
        let bg = pageGround
        var marked = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let p = rgb(x: x, y: y)
                if abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 0.08 { marked += 1 }
            }
        }
        return Double(marked) / Double((height / 2) * (width / 2))
    }

    var pagePeakContrast: Double {
        let bg = pageGround
        var best = 1.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                best = max(best, PanelRaster.contrast(rgb(x: x, y: y), bg))
            }
        }
        return best
    }

    /// Sampled pixels reaching a contrast against the window ground.
    func pagePixelsAbove(contrast target: Double) -> Int {
        let bg = pageGround
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                if PanelRaster.contrast(rgb(x: x, y: y), bg) >= target { count += 1 }
            }
        }
        return count
    }


    /// The raster with every hue removed, as WCAG relative luminance per
    /// sampled pixel.
    ///
    /// This is how a pixel test can speak to FR-058 at all. If a distinction
    /// were carried by colour ALONE — two marks the same lightness in
    /// different hues — the greyscale versions would be identical, and a
    /// reader who cannot separate the hues would be looking at the same thing
    /// twice. Sampled on the same 2px stride as the other measurements here.
    func luminanceField() -> [Double] {
        var out: [Double] = []
        out.reserveCapacity((height / 2) * (width / 2))
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let p = rgb(x: x, y: y)
                out.append(WCAG.luminance(WCAG.RGB(r: p.0, g: p.1, b: p.2)))
            }
        }
        return out
    }

    /// Share of sampled pixels whose luminance differs by more than `epsilon`.
    static func luminanceDifference(_ a: PanelRaster, _ b: PanelRaster, epsilon: Double = 0.01) -> Double {
        let left = a.luminanceField(), right = b.luminanceField()
        guard left.count == right.count, !left.isEmpty else { return 1 }
        var differing = 0
        for index in left.indices where abs(left[index] - right[index]) > epsilon {
            differing += 1
        }
        return Double(differing) / Double(left.count)
    }

    /// Ink inside the outermost `margin` device pixels of the left and right
    /// edges.
    ///
    /// The page pads itself by `DS.lg`, so a render whose content fits paints
    /// nothing out there. Content too wide for 800pt is clipped by the scroll
    /// view at the boundary, which leaves cut glyphs and card edges exactly
    /// here — which is how a pixel test can speak to horizontal overflow at
    /// all (FR-056).
    func edgeInk(margin: Int) -> Int {
        let bg = pageGround
        var marked = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in 0..<margin {
                for column in [x, width - 1 - x] {
                    let p = rgb(x: column, y: y)
                    if abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 0.08 { marked += 1 }
                }
            }
        }
        return marked
    }
}
