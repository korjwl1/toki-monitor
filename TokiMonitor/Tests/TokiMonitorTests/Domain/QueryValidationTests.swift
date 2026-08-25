import Testing
import Foundation
@testable import TokiMonitor

/// The sync server used to answer every query it could not parse with the
/// result of a different one — `usage{model="…"}` returned every model,
/// `avg(…)` returned a sum, `… offset 7d` returned the unshifted window — and
/// the response looked like a success. `toki_sync` now refuses those (contract
/// Q1), and this is the client-side half: the editor says which part the
/// selected backend cannot execute BEFORE the query is sent (Q3).
///
/// So the table below is the same list of shapes, asserted from the other end.
@Suite("Query validation per backend")
@MainActor
struct QueryValidationTests {

    private func check(_ query: String, _ backend: QueryBackend) -> QueryValidation {
        QueryValidation.validate(query, backend: backend)
    }

    private func span(_ query: String, _ backend: QueryBackend) -> String? {
        guard let range = check(query, backend).span else { return nil }
        return String(Array(query)[range])
    }

    // MARK: - What both backends execute

    @Test("the shapes both backends parse are accepted for both", arguments: [
        "usage",
        "cost",
        "events",
        "toki_tokens_total[1h]",
        "usage[1d]",
        "sum(usage[1d])",
        "sum by (model) (increase(usage[1h]))",
        "increase(usage[1d]) by (model)",
        "usage{provider=\"codex\"}[1h] by (model)",
        "events by (project)",
        "sum by (model) (usage)",
    ])
    func acceptedEverywhere(_ query: String) {
        for backend in QueryBackend.allCases {
            let v = check(query, backend)
            #expect(v.isValid, "\(backend) should accept \(query): \(v.reason ?? "")")
        }
    }

    // MARK: - What only the local daemon executes
    //
    // Each of these is a query the old server scanner answered with something
    // else. The reason must name what is unsupported, not merely report that
    // something is — "invalid query" leaves the reader guessing which token.

    @Test("the sync backend refuses a filter it cannot apply, and names the label")
    func serverRefusesModelFilter() {
        let v = check("usage{model=\"claude-opus-4-6\"}", .server)
        #expect(!v.isValid)
        #expect(v.reason?.contains("model") == true)
        #expect(span("usage{model=\"claude-opus-4-6\"}", .server) == "model")
        #expect(check("usage{model=\"claude-opus-4-6\"}", .local).isValid,
                "the daemon filters on model")
    }

    @Test("the sync backend refuses aggregations it does not compute")
    func serverRefusesAggregations() {
        for query in ["avg(usage[1d])", "count(usage[1d])"] {
            let v = check(query, .server)
            #expect(!v.isValid, "\(query) should be refused")
            #expect(v.reason?.contains("sum") == true,
                    "the refusal should say which aggregation is available")
            #expect(check(query, .local).isValid, "the daemon computes it")
        }
    }

    @Test("the sync backend refuses offset and says where it works")
    func serverRefusesOffset() {
        let v = check("usage[1d] offset 7d", .server)
        #expect(!v.isValid)
        #expect(v.reason?.contains("offset") == true)
        #expect(span("usage[1d] offset 7d", .server) == "offset")
        #expect(check("usage[1d] offset 7d", .local).isValid)
    }

    @Test("metrics the sync backend does not serve are named as local-only",
          arguments: ["sessions", "projects"])
    func serverRefusesLocalOnlyMetrics(_ metric: String) {
        let v = check(metric, .server)
        #expect(!v.isValid)
        #expect(v.reason?.contains(metric) == true)
        #expect(check(metric, .local).isValid)
    }

    /// `windows` is the one metric the sync server answers outside its PromQL
    /// parser — `toki_query` matches the bare string before parsing. Refusing
    /// it would be a false rejection of a query the backend executes; accepting
    /// `windows{...}` would be a promise the parser breaks.
    @Test("the bare `windows` query is accepted by both, and only bare on the server")
    func bareWindows() {
        #expect(check("windows", .server).isValid)
        #expect(check("windows", .local).isValid)
        for wrapped in ["windows{}", "windows{provider=\"codex\"}", "windows[1d]",
                        "sum(windows)", "windows by (model)"] {
            let v = check(wrapped, .server)
            #expect(!v.isValid, "\(wrapped) should be refused")
            #expect(v.reason?.contains("windows") == true)
        }
        #expect(check("windows{provider=\"codex\"}", .local).isValid,
                "the daemon does filter windows")
    }

    /// Autocomplete may offer LESS than the validator accepts — `windows` runs
    /// against the sync server but this client cannot render its response — so
    /// the drift tests run one way only, and this pins the exception rather
    /// than leaving it to be rediscovered as a bug.
    @Test("a query the backend executes but the app cannot render is not offered")
    func acceptedButNotOffered() {
        #expect(check("windows", .server).isValid)
        #expect(!PromQLSuggester.metrics(.server).map(\.text).contains("windows"))
        #expect(PromQLSuggester.metrics(.local).map(\.text).contains("windows"))
    }

    @Test("the sync backend groups by one label only")
    func serverRefusesTwoGroupLabels() {
        let v = check("sum by (model, project) (usage[1d])", .server)
        #expect(!v.isValid)
        #expect(v.reason?.contains("model") == true && v.reason?.contains("project") == true)
        #expect(check("sum by (model, project) (usage[1d])", .local).isValid)
    }

    @Test("a group label neither backend has is refused with the ones it has")
    func unknownGroupLabel() {
        let v = check("usage by (region)", .local)
        #expect(!v.isValid)
        #expect(v.reason?.contains("region") == true)
        #expect(v.reason?.contains("model") == true, "it should list what is groupable")
        #expect(span("usage by (region)", .local) == "region")
    }

    @Test("group labels differ per backend in both directions")
    func groupLabelsDifferPerBackend() {
        #expect(check("usage by (device_id)", .server).isValid)
        #expect(!check("usage by (device_id)", .local).isValid,
                "one machine's daemon has no device dimension")
        #expect(check("usage by (session)", .local).isValid)
        #expect(!check("usage by (session)", .server).isValid)
    }

    @Test("`by (type)` is accepted by the server, which already splits by kind")
    func typeIsIgnoredNotRefused() {
        #expect(check("sum by (type) (usage[1d])", .server).isValid)
    }

    @Test("a regex matcher is local-only")
    func regexMatcher() {
        #expect(check("usage{model=~\"opus.*\"}", .local).isValid)
        let v = check("usage{provider=~\"codex\"}", .server)
        #expect(!v.isValid)
        #expect(v.reason?.contains("=~") == true)
    }

    // MARK: - What neither backend executes

    @Test("a function no backend implements is refused on both",
          arguments: ["rate(usage[5m])", "max(usage[1d])", "topk(3, usage[1d])"])
    func noBackendHasIt(_ query: String) {
        for backend in QueryBackend.allCases {
            #expect(!check(query, backend).isValid, "\(backend) should refuse \(query)")
        }
    }

    @Test("a typo in the metric name is a refusal, not a substitute result")
    func typoIsRefused() {
        for backend in QueryBackend.allCases {
            let v = check("usge", backend)
            #expect(!v.isValid)
            #expect(v.reason?.contains("usge") == true, "the refusal names the typo")
            #expect(v.reason?.contains("usage") == true, "and what was meant")
        }
    }

    @Test("syntax that never parses is refused with the position", arguments: [
        "", "usage{model=\"x\"", "usage{model=}", "sum(usage[1d]", "usage[1x]",
        "usage by (", "usage extra",
    ])
    func brokenSyntax(_ query: String) {
        #expect(!check(query, .local).isValid, "\(query) should not validate")
    }

    @Test("an empty query says it is empty")
    func emptyQuery() {
        let v = check("   ", .local)
        #expect(!v.isValid)
        #expect(v.span == nil, "there is no position to point at")
    }

    @Test("a list metric refuses buckets and grouping")
    func listMetrics() {
        #expect(!check("sessions[1d]", .local).isValid)
        #expect(!check("projects by (model)", .local).isValid)
        #expect(check("sessions{project=\"toki\"}", .local).isValid)
    }

    // MARK: - Autocomplete and validation cannot drift apart (T027)
    //
    // These are the tests that fail if a term is added to one side only. The
    // suggester and the validator read `QueryVocabulary`; if either grew its
    // own list again, one of these would break.

    @Test("every metric autocomplete offers is one the same backend parses")
    func offeredMetricsValidate() {
        for backend in QueryBackend.allCases {
            for metric in PromQLSuggester.metrics(backend) {
                let v = check(metric.text, backend)
                #expect(v.isValid,
                        "\(backend) offers \(metric.text) but refuses it: \(v.reason ?? "")")
            }
        }
    }

    @Test("every label autocomplete offers is usable as a filter or a grouping")
    func offeredLabelsValidate() {
        for backend in QueryBackend.allCases {
            for label in PromQLSuggester.labels(backend) {
                let asFilter = check("usage{\(label.text)=\"x\"}", backend).isValid
                let asGroup = check("usage by (\(label.text))", backend).isValid
                #expect(asFilter || asGroup,
                        "\(backend) offers \(label.text) in neither position")
            }
        }
    }

    @Test("a label the backend rejects is not offered for it")
    func rejectedLabelsAreNotOffered() {
        #expect(!PromQLSuggester.labels(.local).map(\.text).contains("device_id"))
        #expect(!PromQLSuggester.labels(.server).map(\.text).contains("session"))
    }

    @Test("every aggregation autocomplete offers is one the backend computes")
    func offeredFunctionsValidate() {
        for backend in QueryBackend.allCases {
            let offered = Set(PromQLSuggester.functions(backend).map(\.text))
            for aggregation in ["sum", "avg", "count"] {
                let parses = check("\(aggregation)(usage[1d])", backend).isValid
                #expect(offered.contains(aggregation) == parses,
                        "\(backend): offered=\(offered.contains(aggregation)) parses=\(parses) for \(aggregation)")
            }
            #expect(offered.contains("offset") == check("usage[1d] offset 1d", backend).isValid)
        }
    }

    // MARK: - Ad hoc filters (contract Q4)

    private func adHoc(_ filters: [AdHocFilter]) -> DashboardVariable {
        var v = DashboardVariable(name: "filters", type: .custom)
        v.plugin = VariablePluginRef(kind: BuiltinVariablePluginKind.adHoc, spec: Data())
        v.adHocFilters = filters
        return v
    }

    @Test("a filter that lands is reported as applied")
    func filterApplied() {
        let (query, validation) = QueryValidation.check(
            template: "sum(usage[1h]) by (model)",
            time: TimeConfig(),
            variables: [adHoc([AdHocFilter(key: "project", op: .equals, value: "toki")])],
            backend: .local
        )
        #expect(query.contains("project=\"toki\""))
        #expect(validation.appliedFilters.applied == ["project"])
        #expect(validation.appliedFilters.allApplied)
        #expect(!validation.appliedFilters.hasUnapplied)
    }

    /// The case the contract is about: the rewriter finds no selector, returns
    /// the query untouched, and the panel shows unfiltered data. Nothing used
    /// to record that.
    @Test("a filter that cannot be placed is reported as unapplied, with a reason")
    func filterNotApplied() {
        let (query, validation) = QueryValidation.check(
            template: "unknown_metric[1h]",
            time: TimeConfig(),
            variables: [adHoc([AdHocFilter(key: "project", op: .equals, value: "toki")])],
            backend: .local
        )
        #expect(query == "unknown_metric[1h]", "the query is left alone, as before")
        #expect(validation.appliedFilters.unapplied == ["project"])
        #expect(!validation.appliedFilters.allApplied)
        #expect(validation.appliedFilters.reason?.isEmpty == false,
                "the reader has to be able to read why")
    }

    @Test("an unfinished filter is neither applied nor missing")
    func emptyKeyIsNotRequested() {
        let rewrite = QueryRewriter.rewrite(
            [AdHocFilter(key: "", op: .equals, value: "toki")], in: "usage[1h]"
        )
        #expect(rewrite.query == "usage[1h]")
        #expect(rewrite.appliedFilters.isEmpty)
        #expect(rewrite.appliedFilters.allApplied)
    }

    /// A filter can be applied AND make the query unexecutable: the reader
    /// filters on `project` while pointed at the sync backend, which can only
    /// filter on `provider`. Both facts are reported by the same verdict.
    @Test("a filter that applies can still be one the backend refuses")
    func appliedButUnsupported() {
        let (query, validation) = QueryValidation.check(
            template: "usage[1h]",
            time: TimeConfig(),
            variables: [adHoc([AdHocFilter(key: "project", op: .equals, value: "toki")])],
            backend: .server
        )
        #expect(query.contains("project=\"toki\""))
        #expect(validation.appliedFilters.allApplied)
        #expect(!validation.isValid)
        #expect(validation.reason?.contains("project") == true)
    }

    @Test("validation without filters reports nothing about them")
    func noFilterReport() {
        let v = check("usage[1h]", .local)
        #expect(v.isValid)
        #expect(v.appliedFilters.isEmpty)
        #expect(v.appliedFilters.allApplied)
    }
}
