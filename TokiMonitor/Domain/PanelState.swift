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
    /// There are rows, but every series is currently hidden.
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

    /// Why the panel looks like this, and what to do next. `nil` where the
    /// title already says everything.
    var detail: String? {
        switch self {
        case .idle:
            return L.tr("새로 고치면 이 패널의 쿼리를 실행합니다.",
                        "Refresh to run this panel's query.")
        case .loading:
            return nil
        case .loaded:
            return nil
        case .empty(let reason):
            switch reason {
            case .noDataInRange:
                return L.tr("쿼리는 성공했지만 선택한 시간 범위에 해당하는 행이 없습니다. 범위를 넓히거나 쿼리의 필터를 확인하세요.",
                            "The query succeeded but matched no rows in the selected time range. Widen the range, or check the query's filters.")
            case .allSeriesHidden:
                return L.tr("데이터는 있습니다. 툴바에서 모델을 다시 켜면 보입니다.",
                            "The data is there. Turn a model back on in the toolbar to see it.")
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

    /// What assistive technology reads for the panel as a whole.
    var accessibilityDescription: String {
        [title, detail].compactMap { $0 }.joined(separator: ". ")
    }
}
