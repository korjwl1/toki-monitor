import Foundation

/// Token categories that the suggester recognizes. The category drives the
/// SF Symbol shown next to the suggestion so the user can tell what kind of
/// thing they're inserting.
enum PromQLSuggestionKind: String, Sendable {
    case metric
    case label
    case function
    case variable
    case rangeVector

    var systemImage: String {
        switch self {
        case .metric:      return "chart.bar"
        case .label:       return "tag"
        case .function:    return "function"
        case .variable:    return "dollarsign.circle"
        case .rangeVector: return "timer"
        }
    }
}

struct PromQLSuggestion: Identifiable, Hashable, Sendable {
    let text: String
    let kind: PromQLSuggestionKind
    /// Optional hint shown under the suggestion (e.g. "by (model, project)"
    /// or "1m / 5m / 1h …"). Keeps the list scannable without a full docs
    /// popover.
    let hint: String?

    var id: String { "\(kind.rawValue):\(text)" }
}

/// Static suggestion engine for the toki-monitor explore view.
///
/// Not a real PromQL parser. Neither backend is one either, and they do not
/// accept the same subset:
///
/// - the local daemon parses `sum`/`avg`/`count`, an optional `increase(...)`
///   wrapper, `by (...)` and `offset` over the metrics it knows
///   (toki/src/query_parser.rs `parse`);
/// - the sync server does less still — it looks for `cost{`/`events{` and a
///   `by (...)` clause and ignores everything else
///   (toki_sync `parse_toki_virtual_query`).
///
/// So the vocabulary is per datasource. Suggesting `rate` or `max` was worse
/// than suggesting nothing: neither backend implements them and neither
/// reports that, so the query returns a plausible number computed from a
/// different expression than the one on screen. Same for `$__rate_interval`,
/// which nothing expands.
enum PromQLSuggester {

    /// Which backend the suggestions must be valid for.
    enum Dialect: Sendable {
        case local
        case server
    }

    // MARK: - Vocabulary

    /// Metric names both backends accept.
    static let metrics: [PromQLSuggestion] = [
        .init(text: "usage",  kind: .metric, hint: "token usage"),
        .init(text: "cost",   kind: .metric, hint: "USD cost"),
        .init(text: "events", kind: .metric, hint: "API call count"),
    ]

    /// Metrics only the local daemon knows. The server has no parser branch
    /// for them, so offering them against a server datasource would produce a
    /// silent fall-through to `usage`.
    static let localOnlyMetrics: [PromQLSuggestion] = [
        .init(text: "windows",  kind: .metric, hint: "rate-limit windows (intervals)"),
        .init(text: "sessions", kind: .metric, hint: "session ids"),
        .init(text: "projects", kind: .metric, hint: "project names"),
    ]

    /// Labels that `aggregate_events_to_toki_json` actually groups on.
    /// `device_id` requires the toki-sync PR `feature/device-id-groupby`.
    static let labels: [PromQLSuggestion] = [
        .init(text: "model",     kind: .label, hint: "model name"),
        .init(text: "project",   kind: .label, hint: "project path"),
        .init(text: "provider",  kind: .label, hint: "claude_code | codex"),
        .init(text: "device_id", kind: .label, hint: "per-device split"),
    ]

    /// Functions both backends honour.
    static let functions: [PromQLSuggestion] = [
        .init(text: "sum",      kind: .function, hint: "sum series"),
        .init(text: "increase", kind: .function, hint: "delta over range"),
        .init(text: "by",       kind: .function, hint: "group by (label)"),
    ]

    /// Aggregations and modifiers only the local parser implements.
    static let localOnlyFunctions: [PromQLSuggestion] = [
        .init(text: "avg",    kind: .function, hint: "average per event"),
        .init(text: "count",  kind: .function, hint: "count events"),
        .init(text: "offset", kind: .function, hint: "shift the window back"),
    ]

    static let variables: [PromQLSuggestion] = [
        .init(text: "$provider",         kind: .variable, hint: "active provider filter"),
        .init(text: "$__interval",       kind: .variable, hint: "auto bucket width"),
    ]

    static let rangeVectors: [PromQLSuggestion] = [
        .init(text: "[5m]",          kind: .rangeVector, hint: nil),
        .init(text: "[15m]",         kind: .rangeVector, hint: nil),
        .init(text: "[1h]",          kind: .rangeVector, hint: nil),
        .init(text: "[1d]",          kind: .rangeVector, hint: nil),
        .init(text: "[$__interval]", kind: .rangeVector, hint: nil),
    ]

    /// Full vocabulary for a dialect, in display order.
    static func all(_ dialect: Dialect) -> [PromQLSuggestion] {
        switch dialect {
        case .local:
            return metrics + localOnlyMetrics + functions + localOnlyFunctions
                + labels + variables + rangeVectors
        case .server:
            return metrics + functions + labels + variables + rangeVectors
        }
    }

    // MARK: - Suggestion

    /// Pick the active token at the end of `query` and return matching
    /// suggestions. "Token" here means *the last word the user is typing* —
    /// from the most recent whitespace / `(` / `,` / `{` / `[` boundary up
    /// to the end of the string. This is the part the suggester is allowed
    /// to replace when the user accepts a suggestion.
    static func suggestions(for query: String,
                            dialect: Dialect = .local) -> (token: String, items: [PromQLSuggestion]) {
        let token = currentToken(in: query)
        let vocabulary = all(dialect)
        if token.isEmpty {
            // Empty input or just-typed boundary → show a useful starter set.
            return (token, vocabulary.filter { $0.kind == .metric || $0.kind == .function })
        }

        let lower = token.lowercased()
        // Case-insensitive prefix match *and* case-insensitive identity
        // check — typing "SUM" should still surface the lowercase
        // `sum` suggestion (the original code compared `$0.text != token`
        // case-sensitively, leaking duplicates).
        let matches = vocabulary.filter {
            $0.text.lowercased().hasPrefix(lower) && $0.text.lowercased() != lower
        }
        return (token, matches)
    }

    /// Apply a chosen suggestion: replace the active token at the end of
    /// `query` with `suggestion.text`. Range vector suggestions don't get a
    /// trailing space (you usually want to keep typing right after); the
    /// rest get one so the next token can begin naturally.
    static func apply(_ suggestion: PromQLSuggestion, to query: String) -> String {
        let token = currentToken(in: query)
        let trimmed = String(query.dropLast(token.count))
        let suffix = suggestion.kind == .rangeVector ? "" : " "
        return trimmed + suggestion.text + suffix
    }

    // MARK: - Tokenization

    private static let tokenBoundaries: Set<Character> = [
        " ", "\t", "\n", "(", ")", ",", "{", "}", "[", "]"
    ]

    /// Last identifier-ish run at the end of `query`. Includes `$` so
    /// `$prov` returns `$prov` (variable prefix), and includes `[` so
    /// `[1` returns `[1` (range vector prefix).
    private static func currentToken(in query: String) -> String {
        var token = ""
        for ch in query.reversed() {
            if tokenBoundaries.contains(ch) {
                // `[` is a boundary *and* a token starter for range vectors —
                // include it in the active token.
                if ch == "[" { token = "[" + token }
                break
            }
            token = String(ch) + token
        }
        return token
    }
}
