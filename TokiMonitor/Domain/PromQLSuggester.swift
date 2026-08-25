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
/// accept the same subset, so the vocabulary is per backend and comes from
/// `QueryVocabulary` — the same table `QueryValidation` enforces.
///
/// That sharing is the point. Suggesting `rate` or `max` was worse than
/// suggesting nothing: neither backend implements them and neither reported
/// that, so the query returned a plausible number computed from a different
/// expression than the one on screen. A completion the validator would reject,
/// or a term the validator accepts and autocomplete never offers, is the same
/// defect in a different direction — so neither side keeps its own list.
///
/// What stays here is what the EDITOR adds rather than what a backend parses:
/// dashboard variables and range-vector shortcuts.
enum PromQLSuggester {

    /// Which backend the suggestions must be valid for.
    typealias Dialect = QueryBackend

    // MARK: - Vocabulary

    static func metrics(_ dialect: Dialect) -> [PromQLSuggestion] {
        suggestions(dialect.vocabulary.metrics, kind: .metric)
    }

    /// Aggregations and range functions — everything that may wrap a selector.
    static func functions(_ dialect: Dialect) -> [PromQLSuggestion] {
        suggestions(dialect.vocabulary.aggregations, kind: .function)
            + suggestions(dialect.vocabulary.rangeFunctions, kind: .function)
            + [byTerm]
            + (dialect.vocabulary.supportsOffset ? [offsetTerm] : [])
    }

    /// Filter and group keys together: at the moment a label is being typed,
    /// the suggester cannot yet know which of the two positions it will land in.
    static func labels(_ dialect: Dialect) -> [PromQLSuggestion] {
        suggestions(dialect.vocabulary.labelKeys, kind: .label)
    }

    /// `by` and `offset` are grammar, not functions, and so are not in the
    /// vocabulary's function lists; the editor still completes them.
    private static let byTerm = PromQLSuggestion(
        text: "by", kind: .function, hint: "group by (label)"
    )
    private static let offsetTerm = PromQLSuggestion(
        text: "offset", kind: .function, hint: "shift the window back"
    )

    private static func suggestions(_ terms: [QueryVocabulary.Term],
                                    kind: PromQLSuggestionKind) -> [PromQLSuggestion] {
        terms.filter(\.suggested).map { .init(text: $0.name, kind: kind, hint: $0.hint) }
    }

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
        metrics(dialect) + functions(dialect) + labels(dialect) + variables + rangeVectors
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
