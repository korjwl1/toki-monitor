import Foundation

// MARK: - Wire → Frame
//
// Builds frames from the CURRENT report JSON, without waiting for a wire
// change. The wire encodes grouping dimensions positionally inside the period
// string (`"2026-08-10T00:00:00|opus-5|toki"`), and the daemon joins them in
// the order the query asked for (`build_group_key`, toki/src/query.rs:527 —
// `for (i, dim) in group_by.iter().enumerate()`). So the DIMENSION NAMES can
// be recovered from the query's own `by (...)` clause and mapped positionally.
//
// That is the whole trick: named, multi-dimensional labels today, from a wire
// that carries none. When the daemon grows a frame-native output the adapter
// gets simpler, not obsolete — the parsing moves, the contract does not.

enum FrameAdapter {

    /// Dimension names from a query's `by (...)` / `by(...)` clause, in the
    /// order written. Order is what makes positional recovery valid.
    static func groupByDimensions(in query: String) -> [String] {
        guard let byRange = query.range(of: #"by\s*\("#, options: .regularExpression) else {
            return []
        }
        let afterBy = query[byRange.upperBound...]
        guard let close = afterBy.firstIndex(of: ")") else { return [] }
        return afterBy[..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Convert one report response into frames.
    ///
    /// - Parameters:
    ///   - report: decoded provider → entries map (the V2 envelope).
    ///   - query: the interpolated query text, used to name the dimensions and
    ///     recorded on each frame for Inspect.
    ///   - refId: which query in the panel produced this.
    ///   - datasource: for provenance.
    ///   - time: the requested window. Supplied, every frame spans the whole of
    ///     it; the daemon only emits buckets that contain events, so without it
    ///     a "last 24 hours" chart shows only the hours that had traffic, and
    ///     each series covers only its own buckets rather than a shared axis.
    static func frames(
        providers: [String: [TokiReportEntry]],
        query: String,
        refId: String = "A",
        datasource: String? = nil,
        time: TimeConfig? = nil
    ) -> FrameSet {
        let dimensions = groupByDimensions(in: query)
        var out: [Frame] = []
        var notices: [String] = []

        let axis = timeAxis(providers: providers, time: time, notices: &notices)
        var slot: [Date: Int] = [:]
        for (i, date) in axis.enumerated() { slot[date] = i }

        // series identity -> measures, one column per axis slot
        // Built per provider so provider is never merged away, which the old
        // parser did unconditionally (`for (_, entries) in report.providers`).
        for providerName in providers.keys.sorted() {
            let entries = providers[providerName] ?? []
            var series: [SeriesKey: SeriesAccumulator] = [:]

            for entry in entries {
                guard let periodStr = entry.period,
                      let models = entry.usagePerModels else { continue }
                let (dateString, tail) = splitPeriod(periodStr)
                guard let date = TokiReportParser.parseDate(dateString),
                      let index = slot[date] else { continue }

                for summary in models {
                    var labels = labelsFor(
                        dimensions: dimensions,
                        periodTail: tail,
                        summaryModel: summary.model,
                        notices: &notices
                    )
                    // Legacy payloads carry no provider; an empty key would
                    // render as a blank component in the series name.
                    if !providerName.isEmpty { labels["provider"] = providerName }

                    let key = SeriesKey(labels: labels)
                    series[key, default: SeriesAccumulator(slots: axis.count)]
                        .add(at: index, summary: summary)
                }
            }

            for (key, acc) in series.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
                out.append(acc.frame(refId: refId, times: axis, labels: key.labels,
                                     query: query, datasource: datasource))
            }
        }

        if !notices.isEmpty {
            // Attach to the first frame so Inspect surfaces them; a set with no
            // frames still needs somewhere to put them.
            if out.isEmpty {
                var carrier = Frame(refId: refId)
                carrier.meta = FrameMeta(executedQuery: query, datasource: datasource,
                                         notices: notices)
                out.append(carrier)
            } else {
                out[0].meta.notices.append(contentsOf: notices)
            }
        }
        return FrameSet(frames: out)
    }

    // MARK: - Time axis

    /// The shared time axis: every bucket the response reported, plus every
    /// bucket the requested window contains.
    ///
    /// Only the response's own timestamps are used when `time` is absent, and
    /// the window is ignored entirely when the response carried no parsable
    /// timestamp at all — an instant query's period is a group key rather than
    /// a date, and inventing 15 empty buckets for it would turn one row into a
    /// phantom series.
    private static func timeAxis(
        providers: [String: [TokiReportEntry]],
        time: TimeConfig?,
        notices: inout [String]
    ) -> [Date] {
        var dates = Set<Date>()
        var unparsable = Set<String>()
        for entries in providers.values {
            for entry in entries {
                guard let periodStr = entry.period, entry.usagePerModels != nil else { continue }
                let (dateString, _) = splitPeriod(periodStr)
                if let date = TokiReportParser.parseDate(dateString) {
                    dates.insert(date)
                } else {
                    unparsable.insert(periodStr)
                }
            }
        }
        for period in unparsable.sorted() {
            notices.append("unparsable period: \(period)")
        }
        guard !dates.isEmpty else { return [] }

        if let time {
            let step = TimeInterval(time.bucketSeconds)
            // Match the point path's dedup rule: a reported bucket wins over the
            // generated slot it falls in, so the two never draw at offset times.
            let reported = Set(dates.map { floor($0.timeIntervalSince1970 / step) * step })
            for slot in TimeSeriesGapFiller.bucketStarts(time: time)
            where !reported.contains(slot.timeIntervalSince1970) {
                dates.insert(slot)
            }
        }
        return dates.sorted()
    }

    // MARK: - Dimension recovery

    /// Split `"2026-08-10T00:00:00|a|b"` into the date part and the remaining
    /// components. The date never contains `|`, so the first separator is
    /// unambiguous; the REST is split fully, which is what the old single
    /// split could not do.
    static func splitPeriod(_ period: String) -> (date: String, tail: [String]) {
        guard let pipe = period.firstIndex(of: "|") else { return (period, []) }
        let date = String(period[..<pipe])
        let rest = String(period[period.index(after: pipe)...])
        return (date, rest.isEmpty ? [] : rest.components(separatedBy: "|"))
    }

    /// Map period components onto dimension names.
    ///
    /// Three shapes have to be handled, all verified against the daemon:
    /// - no grouping: the summary's `model` is a real model name
    /// - one dimension that is not `model`: the daemon puts the group value in
    ///   BOTH the period tail and `summary.model` (`inner_key`,
    ///   toki/src/query.rs:439), so a value containing `|` survives intact and
    ///   must be read from `summary.model`, not reassembled from the tail
    /// - several dimensions: values are `|`-joined in query order
    static func labelsFor(
        dimensions: [String],
        periodTail: [String],
        summaryModel: String,
        notices: inout [String]
    ) -> [String: String] {
        if dimensions.isEmpty {
            // "(total)" is the aggregate placeholder, not a series name.
            return summaryModel == "(total)" ? [:] : ["model": summaryModel]
        }

        if dimensions.count == 1 {
            let dim = dimensions[0]
            // Prefer `summary.model`: it is the unsplit value, so a project
            // named "a|b" is preserved. Reassembling the tail would work too,
            // but only by accident.
            let value = summaryModel == "(total)"
                ? periodTail.joined(separator: "|")
                : summaryModel
            return value.isEmpty ? [:] : [dim: value]
        }

        guard periodTail.count == dimensions.count else {
            // A dimension value containing "|" makes positional recovery
            // ambiguous with more than one dimension. Say so rather than
            // silently mislabelling — a wrong label is worse than a missing one.
            notices.append(
                "could not split \(periodTail.count) period components across "
                + "\(dimensions.count) dimensions (\(dimensions.joined(separator: ", ")))"
            )
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: zip(dimensions, periodTail))
    }

    // MARK: - Accumulation

    private struct SeriesKey: Hashable {
        let labels: [String: String]
        var sortKey: String {
            labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
    }

    /// One series' measures, held as columns already aligned to the shared time
    /// axis. Every series therefore spans the same window, which is what lets a
    /// chart draw them together and a table put them in one row per bucket.
    /// A bucket this series never reported stays nil — absent, not zero.
    private struct SeriesAccumulator {
        var input: [Double?]
        var output: [Double?]
        var total: [Double?]
        var events: [Double?]
        var cost: [Double?]
        var cacheCreation: [Double?]
        var cacheRead: [Double?]
        var cachedInput: [Double?]
        var reasoning: [Double?]
        /// Whether any row carried this optional column. A column nobody
        /// reported must not appear as a wall of zeroes.
        var sawCacheCreation = false
        var sawCacheRead = false
        var sawCachedInput = false
        var sawReasoning = false
        var sawCost = false

        init(slots: Int) {
            let empty = [Double?](repeating: nil, count: slots)
            input = empty; output = empty; total = empty; events = empty; cost = empty
            cacheCreation = empty; cacheRead = empty; cachedInput = empty; reasoning = empty
        }

        /// Accumulates rather than overwrites: the same bucket can arrive twice
        /// for one series (e.g. one project reported under two model names).
        mutating func add(at i: Int, summary: TokiModelSummary) {
            total[i] = (total[i] ?? 0) + Double(summary.totalTokens)
            input[i] = (input[i] ?? 0) + Double(summary.inputTokens)
            output[i] = (output[i] ?? 0) + Double(summary.outputTokens)
            events[i] = (events[i] ?? 0) + Double(summary.events)
            if let c = summary.costUsd { cost[i] = (cost[i] ?? 0) + c; sawCost = true }

            func add(_ column: inout [Double?], _ value: UInt64?, _ seen: inout Bool) {
                guard let value else { return }
                column[i] = (column[i] ?? 0) + Double(value)
                seen = true
            }
            add(&cacheCreation, summary.cacheCreationInputTokens, &sawCacheCreation)
            add(&cacheRead, summary.cacheReadInputTokens, &sawCacheRead)
            add(&cachedInput, summary.cachedInputTokens, &sawCachedInput)
            add(&reasoning, summary.reasoningOutputTokens, &sawReasoning)
        }

        func frame(refId: String, times: [Date], labels: [String: String],
                   query: String, datasource: String?) -> Frame {
            var fields: [Field] = [
                Field(name: "time", labels: labels, values: .time(times)),
                Field(name: "total_tokens", labels: labels, values: .number(total)),
                Field(name: "input_tokens", labels: labels, values: .number(input)),
                Field(name: "output_tokens", labels: labels, values: .number(output)),
                Field(name: "events", labels: labels, values: .number(events)),
            ]
            if sawCost {
                fields.append(Field(name: "cost_usd", labels: labels, values: .number(cost)))
            }
            if sawCacheCreation {
                fields.append(Field(name: "cache_creation_input_tokens", labels: labels,
                                    values: .number(cacheCreation)))
            }
            if sawCacheRead {
                fields.append(Field(name: "cache_read_input_tokens", labels: labels,
                                    values: .number(cacheRead)))
            }
            if sawCachedInput {
                fields.append(Field(name: "cached_input_tokens", labels: labels,
                                    values: .number(cachedInput)))
            }
            if sawReasoning {
                fields.append(Field(name: "reasoning_output_tokens", labels: labels,
                                    values: .number(reasoning)))
            }
            return Frame(
                refId: refId,
                name: nil,
                fields: fields,
                meta: FrameMeta(executedQuery: query, datasource: datasource)
            )
        }
    }
}
