import Testing
import Foundation
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
// Rendering is deliberately not here yet: the page is redesigned in a later
// phase, and a harness that pinned today's `PlanFitView` would pin the layout
// this feature exists to replace.

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
