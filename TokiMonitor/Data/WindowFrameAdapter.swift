import Foundation

// MARK: - Window rows → interval frames
//
// A rate-limit window IS an interval: it opens, it fills, it resets, and what
// matters about it is the outcome — how high it peaked, whether it was maxed
// out, how long it took to get there. Until now that data had exactly one
// consumer, `PlanFitView`, because the panel pipeline's contract was
// TimeSeriesData and a window is not a time series.
//
// With the frame contract it is one: a frame whose rows are spans. That makes
// window data drawable in a dashboard panel — the state timeline — without
// flattening it into a series of numbers that pretends the window was sampled.
//
// PlanFit itself stays a view of its own. Its content is percentiles over
// window instances, censoring flags and tier advice: statistics ABOUT the
// intervals, not the intervals. What became embeddable is the intervals.

enum WindowFrameAdapter {

    /// Build one frame per (provider, limit, account) series.
    ///
    /// - Parameter nowMs: used only to describe a window that is still open;
    ///   its span is drawn up to now rather than to a reset that has not
    ///   happened, so an open window does not appear to cover the future.
    static func frames(rowsByProvider: [String: [WindowRow]],
                       nowMs: Int64,
                       query: String = "windows",
                       refId: String = "A",
                       datasource: String? = nil) -> FrameSet {
        var out: [Frame] = []

        for provider in rowsByProvider.keys.sorted() {
            var grouped: [SeriesKey: [WindowRow]] = [:]
            for row in rowsByProvider[provider] ?? [] {
                grouped[SeriesKey(provider: provider, limitId: row.limitId,
                                  account: row.account, kind: row.kind), default: []].append(row)
            }
            for key in grouped.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
                // Ordered by when the window ended, so spans read left to right.
                let rows = (grouped[key] ?? []).sorted { $0.windowEndMs < $1.windowEndMs }
                out.append(frame(rows: rows, key: key, nowMs: nowMs,
                                 query: query, refId: refId, datasource: datasource))
            }
        }
        return FrameSet(frames: out)
    }

    private struct SeriesKey: Hashable {
        let provider: String
        let limitId: String
        let account: String
        let kind: String

        var labels: [String: String] {
            var l = ["limit_id": limitId, "kind": kind]
            if !provider.isEmpty { l["provider"] = provider }
            // An account is a login, and dashboards get shared. Its presence
            // as a label is what lets a panel group by it; whether to show it
            // is the panel's decision, not the adapter's.
            if !account.isEmpty { l["account"] = account }
            return l
        }

        var sortKey: String { "\(provider)|\(limitId)|\(account)|\(kind)" }
    }

    private static func frame(rows: [WindowRow], key: SeriesKey, nowMs: Int64,
                              query: String, refId: String, datasource: String?) -> Frame {
        let labels = key.labels
        var starts: [Date] = []
        var ends: [Date] = []
        var peak: [Double?] = []
        var last: [Double?] = []
        var maxed: [Double?] = []
        var samples: [Double?] = []
        var activeMinutes: [Double?] = []
        var minutesTo100: [Double?] = []

        for row in rows {
            let end = row.finalized
                ? row.windowEndMs
                // Still filling: draw it to now. Drawing to its reset would
                // claim coverage of time that has not happened yet.
                : Swift.min(row.windowEndMs, Swift.max(nowMs, row.firstSeenMs))
            let start = row.windowEndMs - Int64(row.windowMinutes) * 60_000
            starts.append(Date(timeIntervalSince1970: Double(start) / 1000))
            ends.append(Date(timeIntervalSince1970: Double(end) / 1000))
            peak.append(row.peakPct)
            last.append(row.lastPct)
            maxed.append(row.maxedOut ? 1 : 0)
            samples.append(Double(row.nSamples))
            activeMinutes.append(Double(row.activeMs) / 60_000)
            // -1 means it never reached 100%; that is absent, not zero
            // minutes, and zero would read as "hit the limit instantly".
            minutesTo100.append(row.timeTo100Ms >= 0
                                ? Double(row.timeTo100Ms) / 60_000
                                : nil)
        }

        func field(_ name: String, _ values: [Double?]) -> Field {
            Field(name: name, labels: labels, values: .number(values))
        }

        return Frame(
            refId: refId,
            name: nil,
            fields: [
                // `start`/`end` are what mark this frame as spans rather than
                // samples — see `StateTimelineBuilder`.
                Field(name: StateTimelineBuilder.startField, labels: labels, values: .time(starts)),
                Field(name: StateTimelineBuilder.endField, labels: labels, values: .time(ends)),
                field("peak_pct", peak),
                field("last_pct", last),
                field("maxed_out", maxed),
                field("n_samples", samples),
                field("active_minutes", activeMinutes),
                field("minutes_to_100", minutesTo100),
            ],
            meta: FrameMeta(executedQuery: query, datasource: datasource)
        )
    }
}
