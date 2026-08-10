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
    static func frames(
        providers: [String: [TokiReportEntry]],
        query: String,
        refId: String = "A",
        datasource: String? = nil
    ) -> FrameSet {
        let dimensions = groupByDimensions(in: query)
        var out: [Frame] = []
        var notices: [String] = []

        // series identity -> (times, measures)
        // Built per provider so provider is never merged away, which the old
        // parser did unconditionally (`for (_, entries) in report.providers`).
        for providerName in providers.keys.sorted() {
            let entries = providers[providerName] ?? []
            var series: [SeriesKey: SeriesAccumulator] = [:]

            for entry in entries {
                guard let periodStr = entry.period,
                      let models = entry.usagePerModels else { continue }
                let (dateString, tail) = splitPeriod(periodStr)
                guard let date = TokiReportParser.parseDate(dateString) else {
                    notices.append("unparsable period: \(periodStr)")
                    continue
                }

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
                    series[key, default: SeriesAccumulator()].append(date: date, summary: summary)
                }
            }

            for (key, acc) in series.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
                out.append(acc.frame(refId: refId, labels: key.labels,
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

    private struct SeriesAccumulator {
        var dates: [Date] = []
        var input: [Double?] = []
        var output: [Double?] = []
        var total: [Double?] = []
        var events: [Double?] = []
        var cost: [Double?] = []
        var cacheCreation: [Double?] = []
        var cacheRead: [Double?] = []
        var cachedInput: [Double?] = []
        var reasoning: [Double?] = []
        /// Whether any row carried this optional column. A column nobody
        /// reported must not appear as a wall of zeroes.
        var sawCacheCreation = false
        var sawCacheRead = false
        var sawCachedInput = false
        var sawReasoning = false
        var sawCost = false

        mutating func append(date: Date, summary: TokiModelSummary) {
            // Same bucket twice for one series: sum rather than keep the last.
            if let i = dates.lastIndex(of: date) {
                total[i] = (total[i] ?? 0) + Double(summary.totalTokens)
                input[i] = (input[i] ?? 0) + Double(summary.inputTokens)
                output[i] = (output[i] ?? 0) + Double(summary.outputTokens)
                events[i] = (events[i] ?? 0) + Double(summary.events)
                if let c = summary.costUsd { cost[i] = (cost[i] ?? 0) + c; sawCost = true }
                accumulateOptionals(at: i, summary)
                return
            }
            dates.append(date)
            input.append(Double(summary.inputTokens))
            output.append(Double(summary.outputTokens))
            total.append(Double(summary.totalTokens))
            events.append(Double(summary.events))
            cost.append(summary.costUsd)
            if summary.costUsd != nil { sawCost = true }
            cacheCreation.append(summary.cacheCreationInputTokens.map(Double.init))
            cacheRead.append(summary.cacheReadInputTokens.map(Double.init))
            cachedInput.append(summary.cachedInputTokens.map(Double.init))
            reasoning.append(summary.reasoningOutputTokens.map(Double.init))
            if summary.cacheCreationInputTokens != nil { sawCacheCreation = true }
            if summary.cacheReadInputTokens != nil { sawCacheRead = true }
            if summary.cachedInputTokens != nil { sawCachedInput = true }
            if summary.reasoningOutputTokens != nil { sawReasoning = true }
        }

        private mutating func accumulateOptionals(at i: Int, _ s: TokiModelSummary) {
            func add(_ column: inout [Double?], _ value: UInt64?, _ seen: inout Bool) {
                guard let value else { return }
                column[i] = (column[i] ?? 0) + Double(value)
                seen = true
            }
            add(&cacheCreation, s.cacheCreationInputTokens, &sawCacheCreation)
            add(&cacheRead, s.cacheReadInputTokens, &sawCacheRead)
            add(&cachedInput, s.cachedInputTokens, &sawCachedInput)
            add(&reasoning, s.reasoningOutputTokens, &sawReasoning)
        }

        func frame(refId: String, labels: [String: String],
                   query: String, datasource: String?) -> Frame {
            // Sort by time: a chart that plots rows in arrival order draws a
            // scribble when the wire happens to emit buckets out of order.
            let order = dates.indices.sorted { dates[$0] < dates[$1] }
            func reorder(_ c: [Double?]) -> [Double?] { order.map { c[$0] } }

            var fields: [Field] = [
                Field(name: "time", labels: labels, values: .time(order.map { dates[$0] })),
                Field(name: "total_tokens", labels: labels, values: .number(reorder(total))),
                Field(name: "input_tokens", labels: labels, values: .number(reorder(input))),
                Field(name: "output_tokens", labels: labels, values: .number(reorder(output))),
                Field(name: "events", labels: labels, values: .number(reorder(events))),
            ]
            if sawCost {
                fields.append(Field(name: "cost_usd", labels: labels, values: .number(reorder(cost))))
            }
            if sawCacheCreation {
                fields.append(Field(name: "cache_creation_input_tokens", labels: labels,
                                    values: .number(reorder(cacheCreation))))
            }
            if sawCacheRead {
                fields.append(Field(name: "cache_read_input_tokens", labels: labels,
                                    values: .number(reorder(cacheRead))))
            }
            if sawCachedInput {
                fields.append(Field(name: "cached_input_tokens", labels: labels,
                                    values: .number(reorder(cachedInput))))
            }
            if sawReasoning {
                fields.append(Field(name: "reasoning_output_tokens", labels: labels,
                                    values: .number(reorder(reasoning))))
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
