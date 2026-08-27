import Foundation

// MARK: - What a panel is showing right now
//
// `PanelDataState` records what the FETCH did — it has one success case and one
// failure case, and nothing that says "the query worked and there was nothing
// there". The renderer was switching on it directly, and `.idle`, `.loading`
// and `.loaded` shared a branch, so a panel that had never been queried, a
// panel mid-refresh, and a panel whose result was empty all drew the same
// thing: an empty rectangle. A reader could not tell whether the data was
// missing or the app was broken.
//
// This is the render-facing state. It is derived from the fetch state plus what
// the panel actually has to draw, and it is a Domain type on purpose: the
// wording of "why is this empty" is a product decision that a test can pin
// without rendering anything.

/// Why a successful query has nothing to show.
///
/// The reason is carried rather than flattened into one "no data" case because
/// the next action differs: a time range with no rows in it wants a wider
/// range, and a fully-hidden series list wants a series turned back on.
enum PanelEmptyReason: String, Equatable, Sendable, CaseIterable {
    /// The query ran and returned no rows for the selected time range.
    case noDataInRange
    /// There are rows, but every series is hidden from the legend.
    case allSeriesHidden
}

/// The five states every panel type must draw distinguishably (contract R3).
enum PanelState: Equatable, Sendable {
    /// Not queried yet.
    case idle
    /// A query is in flight. `hasPrevious` is true when the panel still holds
    /// the previous result — which stays on screen, dimmed, instead of being
    /// cleared, so a time-range change does not blank the whole dashboard.
    case loading(hasPrevious: Bool)
    /// A result with something in it.
    case loaded
    /// The query succeeded and produced nothing.
    case empty(PanelEmptyReason)
    /// The query failed. Carries the reason verbatim — a panel that says only
    /// "error" sends the reader to the logs.
    case failed(reason: String)
}

// MARK: - Derivation

extension PanelState {

    /// Map a fetch result onto what to draw.
    ///
    /// - Parameters:
    ///   - fetch: what the fetch layer last reported for this panel.
    ///   - hasContent: whether the data the panel would draw from is non-empty.
    ///     For `.loading` this describes the PREVIOUS result, which is exactly
    ///     what `hasPrevious` needs to know.
    ///   - hasVisibleSeries: whether anything survives the series filter.
    static func resolve(
        _ fetch: PanelDataState,
        hasContent: Bool,
        hasVisibleSeries: Bool = true
    ) -> PanelState {
        switch fetch {
        case .idle:
            return .idle
        case .loading:
            return .loading(hasPrevious: hasContent)
        case .loaded:
            guard hasContent else { return .empty(.noDataInRange) }
            guard hasVisibleSeries else { return .empty(.allSeriesHidden) }
            return .loaded
        case .error(let message):
            return .failed(reason: message)
        }
    }

    /// True when the panel's own content is what gets drawn — either as the
    /// result, or held over dimmed while the next one arrives.
    var showsContent: Bool {
        switch self {
        case .loaded: return true
        case .loading(let hasPrevious): return hasPrevious
        case .idle, .empty, .failed: return false
        }
    }

    /// True while the held-over content should be dimmed and non-interactive.
    var isStale: Bool {
        if case .loading(let hasPrevious) = self { return hasPrevious }
        return false
    }
}

// MARK: - What each state says
//
// Kept beside the state rather than in the view so that a test can assert two
// states produce different words without instantiating SwiftUI — and so that
// the strings cannot drift apart between the panel types that show them.

extension PanelState {

    /// SF Symbol for the state. Distinct per state: shape carries the
    /// difference for a reader who does not stop to read the sentence.
    var symbol: String {
        switch self {
        case .idle: return "clock"
        case .loading: return "arrow.clockwise"
        case .loaded: return "chart.line.uptrend.xyaxis"
        case .empty(let reason):
            switch reason {
            case .noDataInRange: return "calendar.badge.exclamationmark"
            case .allSeriesHidden: return "eye.slash"
            }
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    /// One line naming the state.
    var title: String {
        switch self {
        case .idle:
            return L.tr("아직 조회하지 않음", "Not queried yet")
        case .loading:
            return L.tr("불러오는 중", "Loading")
        case .loaded:
            return L.tr("결과", "Result")
        case .empty(let reason):
            switch reason {
            case .noDataInRange:
                return L.tr("이 기간에 데이터가 없음", "No data in this range")
            case .allSeriesHidden:
                return L.tr("모든 계열이 숨겨져 있음", "All series hidden")
            }
        case .failed:
            return L.tr("불러오지 못함", "Could not load")
        }
    }

    /// The one thing the headline cannot say on its own.
    ///
    /// Only two states earn a sentence: a held-over result, where the number
    /// on screen belongs to the previous query and would otherwise be read as
    /// the new one, and a failure, which is meaningless without its reason.
    ///
    /// Idle does not. Empty states keep one short recovery hint: the headline
    /// says what happened, while the hint says what the reader can do next.
    var detail: String? {
        switch self {
        case .idle:
            return nil
        case .loading(let hasPrevious):
            // Only the held-over case has anything to add — and it has to. On
            // screen the previous result is dimmed and carries a progress
            // marker, which is two visual cues and no words: a reader who is
            // told "Loading" and then read a number would take the number for
            // the new one.
            return hasPrevious
                ? L.tr("아래 값은 이전 결과이며, 새 결과를 불러오는 중입니다.",
                       "The values below are the previous result; a new one is on its way.")
                : nil
        case .loaded:
            return nil
        case .empty(let reason):
            switch reason {
            case .noDataInRange:
                return L.tr("기간을 넓히거나 쿼리 필터를 확인하세요.",
                            "Try a wider range or check the query filters.")
            case .allSeriesHidden:
                return L.tr("차트를 보려면 계열을 다시 표시하세요.",
                            "Show a series to display the chart.")
            }
        case .failed(let reason):
            return reason
        }
    }

    /// Whether the state offers a retry. Only failure does: an empty result is
    /// an answer, and re-asking the same question gets the same answer.
    var offersRetry: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether the state offers to show every series again.
    ///
    /// It has to. A panel with every series hidden draws this status instead
    /// of its chart — and the legend is part of the chart, so the control that
    /// got the reader here goes off screen with it. Without a way back from
    /// this state, hiding the last series is a one-way door.
    var offersShowAllSeries: Bool {
        if case .empty(.allSeriesHidden) = self { return true }
        return false
    }

    /// What assistive technology reads for the panel as a whole.
    var accessibilityDescription: String {
        [title, detail].compactMap { $0 }.joined(separator: ". ")
    }
}
