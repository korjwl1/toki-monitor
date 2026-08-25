import Foundation

// MARK: - What each backend's parser accepts
//
// The two backends do not read the same language. The local daemon parses
// `sum`/`avg`/`count`, an optional `increase(...)`, five filter keys and
// `offset` (toki/src/query_parser.rs `parse`). The sync server parses `sum`,
// `increase(...)`, a `provider=` matcher and nothing else
// (toki_sync `parse_toki_virtual_query`).
//
// Before this table there were two descriptions of that difference in the app:
// the suggester's per-dialect lists, and nothing at all on the validation side.
// A vocabulary that is offered by autocomplete but rejected by the backend is
// the same defect as one the validator allows and the backend refuses — in both
// directions the app tells the user something the backend will contradict. So
// there is one table, and both readers take it from here.
//
// This table DESCRIBES the two grammars. It does not define them: the query
// language belongs to the daemon (constitution IV, contract Q6). Adding a term
// here does not make a backend understand it.

/// Which backend a query will be sent to.
enum QueryBackend: String, Sendable, CaseIterable {
    /// The `toki` daemon on this machine.
    case local
    /// The toki-sync PromQL proxy.
    case server

    var displayName: String {
        switch self {
        case .local:  return L.tr("로컬 데몬", "the local daemon")
        case .server: return L.tr("동기화 서버", "the sync backend")
        }
    }

    var other: QueryBackend { self == .local ? .server : .local }

    var vocabulary: QueryVocabulary { QueryVocabulary.of(self) }
}

/// One backend's accepted vocabulary.
struct QueryVocabulary: Sendable {

    /// A word the backend knows, with the one-line hint the editor shows.
    struct Term: Sendable, Equatable {
        let name: String
        let hint: String?
        /// Whether autocomplete offers it. `toki_tokens_total` parses but is
        /// the pre-rename spelling: accepting it keeps saved dashboards
        /// working, offering it would teach the older name to new queries.
        let suggested: Bool

        init(_ name: String, _ hint: String? = nil, suggested: Bool = true) {
            self.name = name
            self.hint = hint
            self.suggested = suggested
        }
    }

    let backend: QueryBackend
    /// Metric names, in display order.
    let metrics: [Term]
    /// Aggregations that may wrap the selector: `sum(…)`, `sum by (…) (…)`.
    let aggregations: [Term]
    /// Range functions: `increase(…)`.
    let rangeFunctions: [Term]
    /// Label keys usable inside `{…}`.
    let filterKeys: [Term]
    /// Label keys usable in `by (…)`.
    let groupKeys: [Term]
    /// Group labels parsed and deliberately ignored rather than refused — the
    /// server emits the token-kind split as columns, so `by (type)` is already
    /// satisfied by the response shape.
    let ignoredGroupKeys: Set<String>
    /// Matcher operators accepted inside `{…}`.
    let matcherOps: [String]
    /// Whether `offset <duration>` shifts the window.
    let supportsOffset: Bool
    /// How many real grouping dimensions the aggregator can split on.
    let maxGroupLabels: Int
    /// Metrics that are a list, not a series: no bucket, no group-by, no
    /// aggregation.
    let listMetrics: Set<String>
    /// Metrics the backend answers only as the whole query, with no matcher,
    /// range, offset, aggregation or grouping around them.
    let bareOnlyMetrics: Set<String>
    /// Whether a bare number is a duration (`[3600]`). The daemon requires a
    /// unit; the server's duration parser takes plain seconds.
    let allowsUnitlessDuration: Bool
    /// Whether `by ()` with no label is accepted (the daemon reads it as "no
    /// grouping"; the server refuses it).
    let allowsEmptyGroupList: Bool
    /// Whether `\"` and `\\` inside a label value are understood.
    let allowsEscapesInValues: Bool
    /// What a second matcher on the same label means.
    let duplicateFilterKeys: DuplicateFilterPolicy

    /// The daemon refuses any repeated filter key; the server keeps a single
    /// `provider` and refuses only two that disagree.
    enum DuplicateFilterPolicy: Sendable {
        case rejected
        case rejectedWhenConflicting
    }

    func metric(named name: String) -> Term? { metrics.first { $0.name == name } }
    func filterKey(named name: String) -> Term? { filterKeys.first { $0.name == name } }
    func groupKey(named name: String) -> Term? { groupKeys.first { $0.name == name } }

    var metricNames: [String] { metrics.map(\.name) }

    /// Filter and group keys together, deduplicated, in a stable order. What
    /// autocomplete offers as "labels": at the point the user is typing one,
    /// the suggester does not yet know whether it will land in `{…}` or in
    /// `by (…)`.
    var labelKeys: [Term] {
        var seen = Set<String>()
        return (filterKeys + groupKeys).filter { seen.insert($0.name).inserted }
    }

    // MARK: - The two tables

    static func of(_ backend: QueryBackend) -> QueryVocabulary {
        switch backend {
        case .local:  return .local
        case .server: return .server
        }
    }

    /// toki/src/query_parser.rs — `parse`, `VALID_FILTER_KEYS`,
    /// `VALID_GROUP_KEYS`.
    static let local = QueryVocabulary(
        backend: .local,
        metrics: [
            Term("usage", "token usage"),
            Term("cost", "USD cost"),
            Term("events", "API call count"),
            Term("windows", "rate-limit windows"),
            Term("sessions", "session ids"),
            Term("projects", "project names"),
            Term("toki_tokens_total", "old spelling of usage",
                 suggested: false),
        ],
        aggregations: [
            Term("sum", "sum series"),
            Term("avg", "average per event"),
            Term("count", "count events"),
        ],
        rangeFunctions: [Term("increase", "delta over range")],
        filterKeys: [
            Term("model", "model name"),
            Term("project", "project path"),
            Term("provider", "claude_code | codex"),
            Term("session", "session id"),
            Term("type", "token kind"),
        ],
        groupKeys: [
            Term("model", "model name"),
            Term("project", "project path"),
            Term("session", "session id"),
        ],
        ignoredGroupKeys: [],
        matcherOps: ["=", "=~"],
        supportsOffset: true,
        maxGroupLabels: Int.max,
        listMetrics: ["windows", "sessions", "projects"],
        bareOnlyMetrics: [],
        allowsUnitlessDuration: false,
        allowsEmptyGroupList: true,
        allowsEscapesInValues: true,
        duplicateFilterKeys: .rejected
    )

    /// toki_sync/src/server/handlers/metrics.rs — `parse_toki_virtual_query`.
    static let server = QueryVocabulary(
        backend: .server,
        metrics: [
            Term("usage", "token usage"),
            Term("cost", "USD cost"),
            Term("events", "API call count"),
            // The sync server answers the bare query `windows` from its own
            // branch, before the PromQL parser sees it — so refusing it here
            // would be a false rejection of a query it executes. It is not
            // OFFERED for the server because this client's PromQL path decodes
            // a toki report, not the window envelope, so completing someone
            // into it would fill a panel with nothing.
            Term("windows", "rate-limit windows", suggested: false),
            Term("toki_tokens_total", "old spelling of usage",
                 suggested: false),
        ],
        aggregations: [Term("sum", "sum series")],
        rangeFunctions: [Term("increase", "delta over range")],
        filterKeys: [
            Term("provider", "claude_code | codex"),
        ],
        groupKeys: [
            Term("model", "model name"),
            Term("project", "project path"),
            Term("device_id", "per-device split"),
        ],
        ignoredGroupKeys: ["type"],
        matcherOps: ["="],
        supportsOffset: false,
        maxGroupLabels: 1,
        listMetrics: [],
        bareOnlyMetrics: ["windows"],
        allowsUnitlessDuration: true,
        allowsEmptyGroupList: false,
        allowsEscapesInValues: false,
        duplicateFilterKeys: .rejectedWhenConflicting
    )
}
