import Foundation

// MARK: - Ad hoc filters
//
// An ad hoc filter has to reach queries that never mention it. Every other
// variable is opt-in: the author writes `$name` where they want it. This one
// is the opposite — the reader adds `project = toki` in the toolbar and every
// panel narrows, including panels written before the filter existed.
//
// Which makes the rewrite the whole problem. Appending text or regex-replacing
// on `{` would corrupt a query whose filter value happens to contain a brace,
// and would silently produce a *valid but wrong* query — the worst outcome,
// because nothing reports it. So this walks the string with the same shape the
// daemon's parser expects (toki/src/query_parser.rs `parse`) and edits only at
// a position it has actually identified.

/// One reader-supplied filter.
struct AdHocFilter: Codable, Equatable, Sendable, Identifiable {
    enum Op: String, Codable, Equatable, Sendable, CaseIterable {
        case equals = "="
        case notEquals = "!="
        case matches = "=~"
        case notMatches = "!~"
    }

    var id: UUID = UUID()
    var key: String
    var op: Op = .equals
    var value: String

    /// `project="toki"` — the value is quoted, with quotes and backslashes in
    /// it escaped, so a value containing `"` cannot close the string early and
    /// turn the rest of the query into syntax.
    var encoded: String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)\(op.rawValue)\"\(escaped)\""
    }
}

enum QueryRewriter {

    /// Metric names the daemon's parser accepts. The rewrite anchors on one of
    /// these rather than on the first identifier, because `sum`, `increase`,
    /// `by` and `offset` are identifiers too.
    static let metricNames: Set<String> = [
        "toki_tokens_total", "usage", "cost", "events",
        "windows", "sessions", "projects",
    ]

    /// The rewrite, and whether it happened.
    ///
    /// `QueryRewriter` has always returned the query unchanged when it could
    /// not find the selector — the right call, since a guessed edit yields a
    /// query that still parses and answers a different question. What was
    /// missing is the second half: the reader saw `project = toki` in the
    /// toolbar and a panel showing every project, with nothing anywhere saying
    /// the filter had not been applied (contract Q4). So the rewrite reports.
    struct Rewrite: Equatable {
        var query: String
        var appliedFilters: AppliedFilters
    }

    /// Add `filters` to `query`'s label matchers, and say what landed.
    static func rewrite(_ filters: [AdHocFilter], in query: String) -> Rewrite {
        // A filter with no key is one the reader has started and not finished.
        // It was never asked for, so it is neither applied nor missing.
        let usable = filters.filter { !$0.key.isEmpty }
        guard !usable.isEmpty else {
            return Rewrite(query: query, appliedFilters: .none)
        }
        let keys = usable.map(\.key)
        guard findSelector(in: query) != nil else {
            return Rewrite(
                query: query,
                appliedFilters: AppliedFilters(
                    applied: [], unapplied: keys,
                    reason: L.tr(
                        "질의에서 지표 선택자를 찾지 못해 필터를 적용하지 못했습니다. 질의가 아는 지표(\(metricNames.sorted().joined(separator: ", "))) 중 하나로 시작해야 필터가 걸립니다.",
                        "The filter was not applied: no metric selector was found in the query. A filter can only be placed on a query naming one of \(metricNames.sorted().joined(separator: ", "))."
                    )
                )
            )
        }
        return Rewrite(
            query: applying(usable, to: query),
            appliedFilters: AppliedFilters(applied: keys, unapplied: [], reason: nil)
        )
    }

    /// Add `filters` to `query`'s label matchers.
    ///
    /// Returns the query unchanged when it cannot find the metric selector.
    /// A filter that silently does not apply is bad; a query mangled into
    /// something that still parses is worse, so an unrecognised shape is left
    /// alone rather than guessed at. Callers that must disclose the difference
    /// use `rewrite(_:in:)`, which reports it.
    static func applying(_ filters: [AdHocFilter], to query: String) -> String {
        let usable = filters.filter { !$0.key.isEmpty }
        guard !usable.isEmpty else { return query }
        guard let selector = findSelector(in: query) else { return query }

        let clause = usable.map(\.encoded).joined(separator: ", ")
        var out = query
        if let brace = selector.braceRange {
            // An existing `{...}`: insert before its close. Filters the reader
            // adds come last, so they narrow whatever the author wrote rather
            // than being overridden by it.
            let inner = query[brace].dropFirst().dropLast()
            let separator = inner.trimmingCharacters(in: .whitespaces).isEmpty ? "" : ", "
            let insertAt = query.index(before: brace.upperBound)
            out.replaceSubrange(insertAt..<insertAt, with: separator + clause)
        } else {
            out.replaceSubrange(selector.nameEnd..<selector.nameEnd, with: "{\(clause)}")
        }
        return out
    }

    // MARK: - Locating the metric selector

    /// Which metric a query asks for, or nil when it names none this parser
    /// knows. One place understands the grammar; callers that need to route on
    /// the metric ask here rather than matching on the text themselves.
    static func metricName(in query: String) -> String? {
        guard let selector = findSelector(in: query) else { return nil }
        var start = selector.nameEnd
        while start > query.startIndex {
            let prev = query.index(before: start)
            guard isIdentifierBody(query[prev]) else { break }
            start = prev
        }
        return String(query[start..<selector.nameEnd])
    }

    struct Selector {
        /// Index just past the metric name — where a `{` would go.
        let nameEnd: String.Index
        /// The existing `{...}`, braces included, when there is one.
        let braceRange: Range<String.Index>?
    }

    /// Find the metric name and its matcher block.
    ///
    /// Walks the string tracking quotes and nesting so a metric name appearing
    /// inside a filter VALUE (`{project="usage"}`) is never mistaken for the
    /// selector, and stops at the first identifier that names a metric.
    static func findSelector(in query: String) -> Selector? {
        var i = query.startIndex
        var inString = false
        var depth = 0

        while i < query.endIndex {
            let c = query[i]
            if inString {
                if c == "\\" {
                    i = query.index(i, offsetBy: 2, limitedBy: query.endIndex) ?? query.endIndex
                    continue
                }
                if c == "\"" { inString = false }
                i = query.index(after: i)
                continue
            }
            switch c {
            case "\"":
                inString = true
                i = query.index(after: i)
            case "{", "[":
                depth += 1
                i = query.index(after: i)
            case "}", "]":
                depth -= 1
                i = query.index(after: i)
            case _ where isIdentifierStart(c) && depth == 0:
                var j = i
                while j < query.endIndex, isIdentifierBody(query[j]) {
                    j = query.index(after: j)
                }
                let word = String(query[i..<j])
                if metricNames.contains(word) {
                    switch braceImmediatelyAfter(j, in: query) {
                    case .absent:            return Selector(nameEnd: j, braceRange: nil)
                    case let .present(range): return Selector(nameEnd: j, braceRange: range)
                    // A `{` the query never closes. Inserting a second block
                    // beside it would produce `usage{a="1"}{project="toki"` —
                    // our damage stacked on top of the reader's typo.
                    case .malformed:         return nil
                    }
                }
                i = j
            default:
                i = query.index(after: i)
            }
        }
        return nil
    }

    private enum BraceLookup {
        case absent
        case present(Range<String.Index>)
        /// Opened and never closed — the query is broken as written.
        case malformed
    }

    /// The `{...}` directly after the metric name, if any. Only whitespace may
    /// separate them — a `{` further along belongs to something else.
    private static func braceImmediatelyAfter(_ index: String.Index,
                                              in query: String) -> BraceLookup {
        var i = index
        while i < query.endIndex, query[i] == " " || query[i] == "\t" {
            i = query.index(after: i)
        }
        guard i < query.endIndex, query[i] == "{" else { return .absent }
        let open = i
        var inString = false
        var j = query.index(after: i)
        while j < query.endIndex {
            let c = query[j]
            if inString {
                if c == "\\" {
                    j = query.index(j, offsetBy: 2, limitedBy: query.endIndex) ?? query.endIndex
                    continue
                }
                if c == "\"" { inString = false }
                j = query.index(after: j)
                continue
            }
            if c == "\"" { inString = true }
            if c == "}" { return .present(open..<query.index(after: j)) }
            j = query.index(after: j)
        }
        // An unterminated `{` is a broken query; refusing to edit it keeps the
        // reader's error visible instead of adding one of ours to it.
        return .malformed
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    private static func isIdentifierBody(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
