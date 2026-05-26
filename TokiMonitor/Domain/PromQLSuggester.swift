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
/// Not a real PromQL parser — toki-sync's `/api/v1/toki/query` endpoint
/// accepts only a tiny subset (the virtual metrics `usage` / `cost` /
/// `events` and a handful of `by (...)` labels). The suggester reflects
/// exactly that subset so users don't get auto-completed into syntax the
/// server will silently ignore.
enum PromQLSuggester {

    // MARK: - Vocabulary

    /// Virtual metric names accepted by toki / toki-sync.
    static let metrics: [PromQLSuggestion] = [
        .init(text: "usage",  kind: .metric, hint: "token usage"),
        .init(text: "cost",   kind: .metric, hint: "USD cost"),
        .init(text: "events", kind: .metric, hint: "API call count"),
    ]

    /// Labels that `aggregate_events_to_toki_json` actually groups on.
    /// `device_id` requires the toki-sync PR `feature/device-id-groupby`.
    static let labels: [PromQLSuggestion] = [
        .init(text: "model",     kind: .label, hint: "model name"),
        .init(text: "project",   kind: .label, hint: "project path"),
        .init(text: "provider",  kind: .label, hint: "claude_code | codex"),
        .init(text: "device_id", kind: .label, hint: "per-device split"),
    ]

    static let functions: [PromQLSuggestion] = [
        .init(text: "sum",      kind: .function, hint: "sum series"),
        .init(text: "increase", kind: .function, hint: "delta over range"),
        .init(text: "rate",     kind: .function, hint: "per-second rate"),
        .init(text: "by",       kind: .function, hint: "group by (label)"),
        .init(text: "avg",      kind: .function, hint: "average"),
        .init(text: "max",      kind: .function, hint: "max"),
        .init(text: "min",      kind: .function, hint: "min"),
        .init(text: "count",    kind: .function, hint: "count series"),
    ]

    static let variables: [PromQLSuggestion] = [
        .init(text: "$provider",         kind: .variable, hint: "active provider filter"),
        .init(text: "$__interval",       kind: .variable, hint: "auto bucket width"),
        .init(text: "$__rate_interval",  kind: .variable, hint: "rate-safe interval"),
    ]

    static let rangeVectors: [PromQLSuggestion] = [
        .init(text: "[5m]",          kind: .rangeVector, hint: nil),
        .init(text: "[15m]",         kind: .rangeVector, hint: nil),
        .init(text: "[1h]",          kind: .rangeVector, hint: nil),
        .init(text: "[1d]",          kind: .rangeVector, hint: nil),
        .init(text: "[$__interval]", kind: .rangeVector, hint: nil),
    ]

    /// Full vocabulary, in display order. Categories that match the current
    /// prefix surface to the top.
    static var all: [PromQLSuggestion] {
        metrics + functions + labels + variables + rangeVectors
    }

    // MARK: - Suggestion

    /// Pick the active token at the end of `query` and return matching
    /// suggestions. "Token" here means *the last word the user is typing* —
    /// from the most recent whitespace / `(` / `,` / `{` / `[` boundary up
    /// to the end of the string. This is the part the suggester is allowed
    /// to replace when the user accepts a suggestion.
    static func suggestions(for query: String) -> (token: String, items: [PromQLSuggestion]) {
        let token = currentToken(in: query)
        if token.isEmpty {
            // Empty input or just-typed boundary → show a useful starter set.
            return (token, metrics + functions)
        }

        let lower = token.lowercased()
        // Case-insensitive prefix match *and* case-insensitive identity
        // check — typing "MAX" should still surface the lowercase
        // `max` suggestion (the original code compared `$0.text != token`
        // case-sensitively, leaking duplicates).
        let matches = all.filter {
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
