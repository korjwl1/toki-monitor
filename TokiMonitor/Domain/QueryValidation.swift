import Foundation

// MARK: - Will this backend understand the query?
//
// Contract Q3: the editor tells the reader, BEFORE sending, whether the
// selected backend can execute what they wrote — and when it cannot, WHICH
// part it cannot. "Invalid query" sends someone to guess; "`offset` is not
// supported by the sync backend" sends them to delete four characters or to
// switch backends.
//
// This is a pre-flight check, not an authority. The daemon owns the query
// language (constitution IV, contract Q6) and the server's own refusal is what
// is displayed when one arrives (Q2). Two consequences follow, and both are
// deliberate:
//
//   - Nothing here EXTENDS the language. The tables it reads describe the two
//     parsers as they are; a term absent from `QueryVocabulary` is absent from
//     both the validator and autocomplete, and adding one here would not make
//     any backend understand it.
//   - A verdict of `isValid` is "nothing recognisably wrong", never a promise
//     of a result. Callers warn on the strength of it; they do not block on it.
//     A false rejection that stops a query the backend would have answered is a
//     worse failure than a warning that turns out to be unnecessary.

/// Whether the ad hoc filters the reader set actually reached the query text.
///
/// `QueryRewriter` returns the query untouched when it cannot find the metric
/// selector — the safe choice, since a guessed edit produces a query that still
/// parses and answers a different question. But untouched means the filter did
/// not apply, and until this type existed nothing said so: the toolbar showed
/// `project = toki` and the panel showed every project (contract Q4).
struct AppliedFilters: Equatable, Sendable {
    /// Filter keys that reached the query text.
    var applied: [String]
    /// Filter keys the rewriter could not place.
    var unapplied: [String]
    /// Why they could not be placed. Nil when everything applied.
    var reason: String?

    static let none = AppliedFilters(applied: [], unapplied: [], reason: nil)

    /// No filter was requested, or every requested filter landed.
    var allApplied: Bool { unapplied.isEmpty }

    /// True when the reader set a filter that the panel is not honouring —
    /// the case a panel must disclose.
    var hasUnapplied: Bool { !unapplied.isEmpty }

    var isEmpty: Bool { applied.isEmpty && unapplied.isEmpty }
}

/// The verdict on one query string for one backend.
struct QueryValidation: Equatable, Sendable {

    /// Nothing in the query is recognisably outside what this backend parses.
    let isValid: Bool

    /// What is unsupported, and — where it helps — where else it works.
    /// Nil exactly when `isValid`.
    let reason: String?

    /// Character offsets of the offending token in the validated string, when
    /// the problem has a position. Offsets are into `Array(query)`, so a
    /// caller mapping them back to `String.Index` must count Characters.
    let span: Range<Int>?

    /// Which ad hoc filters reached the query. Independent of `isValid`: a
    /// perfectly valid query can be one that quietly ignores a filter.
    let appliedFilters: AppliedFilters

    static func valid(appliedFilters: AppliedFilters = .none) -> QueryValidation {
        QueryValidation(isValid: true, reason: nil, span: nil, appliedFilters: appliedFilters)
    }

    static func invalid(_ reason: String,
                        span: Range<Int>? = nil,
                        appliedFilters: AppliedFilters = .none) -> QueryValidation {
        QueryValidation(isValid: false, reason: reason, span: span, appliedFilters: appliedFilters)
    }

    /// Carry a different filter report on the same verdict.
    func with(appliedFilters: AppliedFilters) -> QueryValidation {
        QueryValidation(isValid: isValid, reason: reason, span: span,
                        appliedFilters: appliedFilters)
    }
}

// MARK: - Validating

extension QueryValidation {

    /// Check `query` against `backend`.
    ///
    /// `query` is the text that will be SENT — variables already interpolated
    /// and ad hoc filters already applied. Validating a template would report
    /// `$provider` as a missing label matcher, which is a fact about the
    /// template and not about the query the backend will see.
    static func validate(_ query: String,
                         backend: QueryBackend,
                         appliedFilters: AppliedFilters = .none) -> QueryValidation {
        var check = QueryGrammarCheck(vocabulary: backend.vocabulary, query: query)
        return check.run().with(appliedFilters: appliedFilters)
    }

    /// Interpolate a panel/explore template and check the result, so the
    /// caller gets one verdict covering both "the backend cannot read this"
    /// and "your filter did not apply".
    static func check(template: String,
                      time: TimeConfig,
                      variables: [DashboardVariable],
                      backend: QueryBackend) -> (query: String, validation: QueryValidation) {
        let resolved = VariableResolver.interpolateReporting(
            template: template, time: time, variables: variables
        )
        return (resolved.query,
                validate(resolved.query, backend: backend,
                         appliedFilters: resolved.appliedFilters))
    }
}

// MARK: - The check itself
//
// Structured to walk the same sequence both parsers walk — aggregation
// wrapper, range function, metric, matchers, range selector, offset, closing
// parens, trailing group-by — so that a difference between the two backends is
// a difference in the vocabulary table rather than in the code shape. Where the
// two genuinely disagree (duplicate matchers, `by ()`, escapes) the vocabulary
// says which rule applies.

/// A step that either produced something or refused the query. `Result` would
/// need the verdict to be an `Error`, which it is not: a refusal here is an
/// answer, not a failure of the check.
private enum Parsed<T> {
    case ok(T)
    case refused(QueryValidation)
}

private struct QueryGrammarCheck {
    let vocabulary: QueryVocabulary
    let chars: [Character]
    var pos: Int = 0

    init(vocabulary: QueryVocabulary, query: String) {
        self.vocabulary = vocabulary
        self.chars = Array(query)
    }

    private var backendName: String { vocabulary.backend.displayName }
    private var otherName: String { vocabulary.backend.other.displayName }

    // MARK: Entry

    mutating func run() -> QueryValidation {
        skipWS()
        if atEnd {
            return .invalid(L.tr("질의가 비어 있습니다.", "The query is empty."))
        }

        var groupLabels: [(name: String, span: Range<Int>)] = []
        var haveBy = false
        var openParens = 0

        // ── Aggregation wrapper: `sum(…)` or `sum by (…) (…)` ──
        //
        // An identifier here is an aggregation only when a parenthesised body
        // follows — directly, or after a `by (…)`. A range function is handled
        // one level down, and a metric may carry a TRAILING group-by
        // (`events by (model)`), so a by-clause alone does not make this a call.
        let aggMark = pos
        if let id = ident() {
            skipWS()
            var isWrapper = peek() == "(" && !isRangeFunction(id.text)
            var labels: [(name: String, span: Range<Int>)] = []

            if !isWrapper {
                let byMark = pos
                if let by = ident(), by.text == "by" {
                    switch groupList() {
                    case .refused(let v): return v
                    case .ok(let parsed):
                        skipWS()
                        if peek() == "(" {
                            isWrapper = true
                            labels = parsed
                        } else {
                            pos = byMark
                        }
                    }
                } else {
                    pos = byMark
                }
            }

            if isWrapper {
                guard vocabulary.aggregations.contains(where: { $0.name == id.text }) else {
                    return .invalid(unsupportedCall(id.text), span: id.span)
                }
                haveBy = !labels.isEmpty
                groupLabels = labels
                _ = eat("(")
                openParens += 1
            } else {
                pos = aggMark
            }
        }

        // ── Range function: `increase(…)` ──
        let fnMark = pos
        if let id = ident() {
            skipWS()
            if peek() == "(" {
                guard isRangeFunction(id.text) else {
                    return .invalid(unsupportedRangeFunction(id.text), span: id.span)
                }
                _ = eat("(")
                openParens += 1
            } else {
                pos = fnMark
            }
        }

        // ── Metric ──
        guard let metricToken = ident() else {
            return .invalid(
                L.tr("지표 이름이 와야 하는 자리입니다. \(quotedTail())",
                     "Expected a metric name here. \(quotedTail())"),
                span: pos..<pos
            )
        }
        guard let metric = vocabulary.metric(named: metricToken.text) else {
            return .invalid(unknownMetric(metricToken.text), span: metricToken.span)
        }

        // ── Label matchers ──
        var seenKeys: [String: String] = [:]
        var hasMatchers = false
        if eat("{") {
            hasMatchers = true
            while true {
                if eat("}") { break }
                guard let key = ident() else {
                    return .invalid(
                        L.tr("`{...}` 안에는 라벨 이름이 와야 합니다. \(quotedTail())",
                             "Expected a label name inside `{...}`. \(quotedTail())"),
                        span: pos..<pos
                    )
                }
                guard let op = matcherOperator() else {
                    return .invalid(
                        L.tr("`\(key.text)` 뒤에 라벨 매처가 없습니다. \(quotedTail())",
                             "Expected a label matcher after `\(key.text)`. \(quotedTail())"),
                        span: key.span
                    )
                }
                guard vocabulary.matcherOps.contains(op.text) else {
                    return .invalid(unsupportedOperator(op.text), span: op.span)
                }
                guard vocabulary.filterKey(named: key.text) != nil else {
                    return .invalid(unsupportedFilterKey(key.text), span: key.span)
                }
                let value: String
                switch quotedValue() {
                case .refused(let v): return v
                case .ok(let parsed): value = parsed
                }
                if let previous = seenKeys[key.text] {
                    switch vocabulary.duplicateFilterKeys {
                    case .rejected:
                        return .invalid(
                            L.tr("필터 키 `\(key.text)`가 두 번 나옵니다.",
                                 "Filter key `\(key.text)` appears twice."),
                            span: key.span
                        )
                    case .rejectedWhenConflicting where previous != value:
                        return .invalid(
                            L.tr("`\(key.text)` 필터가 서로 다른 값을 요구합니다.",
                                 "Conflicting `\(key.text)` filters."),
                            span: key.span
                        )
                    case .rejectedWhenConflicting:
                        break
                    }
                }
                if value.isEmpty, vocabulary.backend == .server, key.text == "provider" {
                    return .invalid(
                        L.tr("`provider` 필터 값이 비어 있습니다.",
                             "The `provider` filter must not be empty."),
                        span: key.span
                    )
                }
                seenKeys[key.text] = value

                if eat(",") { continue }
                if eat("}") { break }
                return .invalid(
                    L.tr("`{...}` 안에 `,` 또는 `}`가 와야 합니다. \(quotedTail())",
                         "Expected `,` or `}` inside `{...}`. \(quotedTail())"),
                    span: pos..<pos
                )
            }
        }

        // ── Range selector ──
        var hasBucket = false
        if peek() == "[" {
            let start = pos
            _ = eat("[")
            let textStart = pos
            while let c = peek(), c != "]" { pos += 1 }
            let raw = String(chars[textStart..<pos]).trimmingCharacters(in: .whitespaces)
            guard eat("]") else {
                return .invalid(
                    L.tr("`[` 범위가 닫히지 않았습니다.", "Unterminated `[` range selector."),
                    span: start..<chars.count
                )
            }
            guard isDuration(raw) else {
                return .invalid(
                    L.tr("`[\(raw)]`는 올바른 구간이 아닙니다. w/d/h/m/s 단위를 큰 것부터 쓰세요.",
                         "`[\(raw)]` is not a valid range. Use w/d/h/m/s units, largest first."),
                    span: start..<pos
                )
            }
            hasBucket = true
        }

        // ── offset ──
        let offsetMark = pos
        if let id = ident() {
            if id.text == "offset" {
                guard vocabulary.supportsOffset else {
                    return .invalid(unsupportedOffset(), span: id.span)
                }
                skipWS()
                let durStart = pos
                while let c = peek(), c.isLetter || c.isNumber { pos += 1 }
                let raw = String(chars[durStart..<pos])
                guard isDuration(raw) else {
                    return .invalid(
                        L.tr("`offset \(raw)`는 올바른 기간이 아닙니다. w/d/h/m/s 단위를 쓰세요.",
                             "`offset \(raw)` is not a valid duration. Use w/d/h/m/s units."),
                        span: durStart..<max(durStart, pos)
                    )
                }
            } else {
                pos = offsetMark
            }
        }

        // ── Closing parens ──
        for _ in 0..<openParens {
            guard eat(")") else {
                return .invalid(
                    L.tr("괄호가 닫히지 않았습니다. \(quotedTail())",
                         "Unbalanced parentheses; expected `)`. \(quotedTail())"),
                    span: pos..<pos
                )
            }
        }

        // ── Trailing group-by (`increase(usage[1d]) by (model)`) ──
        let byMark = pos
        if let id = ident() {
            if id.text == "by" {
                if haveBy {
                    return .invalid(
                        L.tr("`by (...)` 절이 두 번 나옵니다.", "Duplicate `by (...)` clause."),
                        span: id.span
                    )
                }
                switch groupList() {
                case .refused(let v): return v
                case .ok(let parsed): groupLabels = parsed
                }
            } else {
                pos = byMark
            }
        }

        skipWS()
        guard atEnd else {
            return .invalid(
                L.tr("해석되지 않은 입력이 남았습니다: `\(String(chars[pos...]))`",
                     "Unexpected trailing input: `\(String(chars[pos...]))`"),
                span: pos..<chars.count
            )
        }

        // ── Grouping dimensions ──
        var dimensions: [String] = []
        for label in groupLabels {
            if vocabulary.ignoredGroupKeys.contains(label.name) { continue }
            guard vocabulary.groupKey(named: label.name) != nil else {
                return .invalid(unsupportedGroupKey(label.name), span: label.span)
            }
            if !dimensions.contains(label.name) { dimensions.append(label.name) }
        }
        if dimensions.count > vocabulary.maxGroupLabels {
            return .invalid(
                L.tr("\(backendName)는 라벨 \(vocabulary.maxGroupLabels)개로만 그룹할 수 있습니다. 요청: \(dimensions.joined(separator: ", "))",
                     "\(backendName) can group by only \(vocabulary.maxGroupLabels) label, got \(dimensions.joined(separator: ", "))"),
                span: groupLabels.last?.span
            )
        }

        // ── Metrics answered only as the whole query ──
        //
        // The sync server reads a bare `windows` in a branch of its own, ahead
        // of the PromQL parser; anything wrapped around it reaches the parser,
        // which refuses it.
        if vocabulary.bareOnlyMetrics.contains(metric.name),
           hasMatchers || hasBucket || openParens > 0 || !groupLabels.isEmpty {
            return .invalid(
                L.tr("`\(metric.name)`는 \(backendName)에서 다른 절 없이 `\(metric.name)` 한 낱말로만 조회할 수 있습니다.",
                     "`\(metric.name)` is only available from \(backendName) as the bare query `\(metric.name)`."),
                span: metricToken.span
            )
        }

        // ── Metrics that are a list, not a series ──
        if vocabulary.listMetrics.contains(metric.name) {
            if hasBucket {
                return .invalid(listMetricRefusal(metric.name,
                                                  what: L.tr("시간 구간", "time buckets")),
                                span: metricToken.span)
            }
            if !groupLabels.isEmpty {
                return .invalid(listMetricRefusal(metric.name,
                                                  what: L.tr("group by", "group by")),
                                span: metricToken.span)
            }
            if openParens > 0 {
                return .invalid(listMetricRefusal(metric.name,
                                                  what: L.tr("집계 함수", "aggregation functions")),
                                span: metricToken.span)
            }
        }
        return .valid()
    }

    // MARK: - Messages
    //
    // Every refusal names the token AND the backend, because the same query is
    // legal against the other one often enough that "not supported" without a
    // subject reads as "you wrote nonsense".

    private func availableElsewhere(_ available: Bool) -> String {
        guard available else { return "" }
        return L.tr(" \(otherName)에서는 사용할 수 있습니다.",
                    " It is available from \(otherName).")
    }

    private func unsupportedCall(_ name: String) -> String {
        let accepted = (vocabulary.aggregations + vocabulary.rangeFunctions)
            .map(\.name).joined(separator: ", ")
        let elsewhere = QueryVocabulary.of(vocabulary.backend.other)
            .aggregations.contains { $0.name == name }
        return L.tr(
            "`\(name)(...)`는 \(backendName)가 계산하지 못합니다. 이 자리에 쓸 수 있는 것: \(accepted).\(availableElsewhere(elsewhere))",
            "`\(name)(...)` is not supported by \(backendName); what it accepts here is \(accepted).\(availableElsewhere(elsewhere))"
        )
    }

    private func unsupportedRangeFunction(_ name: String) -> String {
        let accepted = vocabulary.rangeFunctions.map(\.name).joined(separator: ", ")
        return L.tr(
            "함수 `\(name)`은 \(backendName)가 제공하지 않습니다. 구간 함수는 \(accepted)뿐입니다.",
            "Function `\(name)` is not supported by \(backendName); the only range function is \(accepted)."
        )
    }

    private func unknownMetric(_ name: String) -> String {
        let other = QueryVocabulary.of(vocabulary.backend.other)
        if other.metric(named: name) != nil {
            return L.tr("지표 `\(name)`는 \(otherName)에서만 조회할 수 있습니다.",
                        "Metric `\(name)` is only available from \(otherName).")
        }
        let known = vocabulary.metrics.filter(\.suggested).map(\.name).joined(separator: ", ")
        return L.tr("알 수 없는 지표 `\(name)`. \(backendName)가 아는 지표: \(known).",
                    "Unknown metric `\(name)`. \(backendName) understands \(known).")
    }

    private func unsupportedFilterKey(_ key: String) -> String {
        let accepted = vocabulary.filterKeys.map(\.name).joined(separator: ", ")
        let elsewhere = QueryVocabulary.of(vocabulary.backend.other).filterKey(named: key) != nil
        return L.tr(
            "`\(key)` 필터는 \(backendName)가 적용하지 못합니다. 필터할 수 있는 라벨: \(accepted).\(availableElsewhere(elsewhere))",
            "Filtering on `\(key)` is not supported by \(backendName); it can filter on \(accepted).\(availableElsewhere(elsewhere))"
        )
    }

    private func unsupportedOperator(_ op: String) -> String {
        let accepted = vocabulary.matcherOps.joined(separator: ", ")
        return L.tr("매처 `\(op)`는 \(backendName)가 지원하지 않습니다. 쓸 수 있는 매처: \(accepted).",
                    "Matcher `\(op)` is not supported by \(backendName); it accepts \(accepted).")
    }

    private func unsupportedOffset() -> String {
        L.tr("`offset`은 \(backendName)가 창을 옮기지 못해 무시합니다.\(availableElsewhere(true))",
             "`offset` is not supported by \(backendName) — it cannot shift the window.\(availableElsewhere(true))")
    }

    private func unsupportedGroupKey(_ key: String) -> String {
        let accepted = vocabulary.groupKeys.map(\.name).joined(separator: ", ")
        let elsewhere = QueryVocabulary.of(vocabulary.backend.other).groupKey(named: key) != nil
        return L.tr(
            "`\(key)`로는 \(backendName)가 그룹하지 못합니다. 그룹할 수 있는 라벨: \(accepted).\(availableElsewhere(elsewhere))",
            "Grouping by `\(key)` is not supported by \(backendName); it can group by \(accepted).\(availableElsewhere(elsewhere))"
        )
    }

    private func listMetricRefusal(_ metric: String, what: String) -> String {
        L.tr("`\(metric)`는 목록 지표라 \(what)을 지원하지 않습니다.",
             "`\(metric)` is a list metric and does not support \(what).")
    }

    private func quotedTail() -> String {
        let tail = String(chars[min(pos, chars.count)...])
        return tail.isEmpty
            ? L.tr("질의가 여기서 끝납니다.", "The query ends here.")
            : L.tr("`\(tail)`가 왔습니다.", "Found `\(tail)`.")
    }

    // MARK: - Scanning

    private var atEnd: Bool { pos >= chars.count }

    private func isRangeFunction(_ name: String) -> Bool {
        vocabulary.rangeFunctions.contains { $0.name == name }
    }

    private mutating func skipWS() {
        while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" || chars[pos] == "\n" {
            pos += 1
        }
    }

    private mutating func peek() -> Character? {
        skipWS()
        return pos < chars.count ? chars[pos] : nil
    }

    private mutating func eat(_ c: Character) -> Bool {
        skipWS()
        guard pos < chars.count, chars[pos] == c else { return false }
        pos += 1
        return true
    }

    private mutating func ident() -> (text: String, span: Range<Int>)? {
        skipWS()
        let start = pos
        while pos < chars.count,
              chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" {
            pos += 1
        }
        guard pos > start else { return nil }
        return (String(chars[start..<pos]), start..<pos)
    }

    /// `=`, `!=`, `=~`, `!~` — read whatever is written so an unsupported one
    /// can be named in the message rather than reported as a missing `=`.
    private mutating func matcherOperator() -> (text: String, span: Range<Int>)? {
        skipWS()
        let start = pos
        guard pos < chars.count else { return nil }
        let first = chars[pos]
        guard first == "=" || first == "!" else { return nil }
        pos += 1
        if pos < chars.count, chars[pos] == "~" || (first == "!" && chars[pos] == "=") {
            pos += 1
        } else if first == "!" {
            return (String(chars[start..<pos]), start..<pos)
        }
        return (String(chars[start..<pos]), start..<pos)
    }

    private mutating func quotedValue() -> Parsed<String> {
        skipWS()
        guard peek() == "\"" else {
            return .refused(.invalid(
                L.tr("라벨 값은 따옴표로 감싸야 합니다. \(quotedTail())",
                     "Expected a quoted label value. \(quotedTail())"),
                span: pos..<pos
            ))
        }
        let start = pos
        pos += 1
        var value = ""
        while pos < chars.count {
            let c = chars[pos]
            if c == "\\" {
                guard vocabulary.allowsEscapesInValues else {
                    return .refused(.invalid(
                        L.tr("\(backendName)는 라벨 값 안의 이스케이프(`\\`)를 읽지 못합니다.",
                             "\(backendName) does not support escape sequences in label values."),
                        span: pos..<min(pos + 2, chars.count)
                    ))
                }
                if pos + 1 < chars.count {
                    value.append(chars[pos + 1])
                    pos += 2
                    continue
                }
                pos += 1
                continue
            }
            if c == "\"" {
                pos += 1
                return .ok(value)
            }
            value.append(c)
            pos += 1
        }
        return .refused(.invalid(
            L.tr("따옴표가 닫히지 않았습니다.", "Unterminated quoted label value."),
            span: start..<chars.count
        ))
    }

    /// `( a, b )` after a `by`. Returns the labels with their spans.
    private mutating func groupList() -> Parsed<[(name: String, span: Range<Int>)]> {
        guard eat("(") else {
            return .refused(.invalid(
                L.tr("`by` 뒤에는 `(...)`가 와야 합니다. \(quotedTail())",
                     "`by` must be followed by `(...)`. \(quotedTail())"),
                span: pos..<pos
            ))
        }
        var labels: [(name: String, span: Range<Int>)] = []
        while true {
            if eat(")") { break }
            guard let label = ident() else {
                return .refused(.invalid(
                    L.tr("`by (...)` 안에는 라벨 이름이 와야 합니다. \(quotedTail())",
                         "Expected a label name in `by (...)`. \(quotedTail())"),
                    span: pos..<pos
                ))
            }
            labels.append((label.text, label.span))
            if eat(",") { continue }
            if eat(")") { break }
            return .refused(.invalid(
                L.tr("`by (...)` 안에 `,` 또는 `)`가 와야 합니다. \(quotedTail())",
                     "Expected `,` or `)` in `by (...)`. \(quotedTail())"),
                span: pos..<pos
            ))
        }
        if labels.isEmpty, !vocabulary.allowsEmptyGroupList {
            return .refused(.invalid(
                L.tr("`by ()`에는 라벨이 하나 이상 필요합니다.",
                     "`by ()` needs at least one label."),
                span: pos..<pos
            ))
        }
        return .ok(labels)
    }

    // MARK: - Durations

    /// `1h`, `2h30m`, `7d` — units strictly descending, total positive. A bare
    /// number is a duration only where the backend's own parser reads one.
    private func isDuration(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        if text.allSatisfy(\.isNumber) {
            return vocabulary.allowsUnitlessDuration && (Int(text) ?? 0) > 0
        }
        let ranks: [Character: Int] = ["w": 5, "d": 4, "h": 3, "m": 2, "s": 1]
        var lastRank = Int.max
        var total = 0
        var index = text.startIndex
        while index < text.endIndex {
            let digitsStart = index
            while index < text.endIndex, text[index].isNumber { index = text.index(after: index) }
            guard index > digitsStart, let n = Int(text[digitsStart..<index]) else { return false }
            guard index < text.endIndex, let rank = ranks[text[index]] else { return false }
            guard rank < lastRank else { return false }
            lastRank = rank
            total += n
            index = text.index(after: index)
        }
        return total > 0
    }
}
