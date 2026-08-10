import Testing
import Foundation
@testable import TokiMonitor

/// An ad hoc filter reaches queries that never mention it, so the rewrite is
/// the whole risk. The failure to avoid is not a crash — it is a query that
/// still parses and returns the wrong numbers, because nothing reports that.
@Suite("Ad hoc query rewriting")
struct QueryRewriterTests {

    private func filter(_ key: String, _ value: String) -> AdHocFilter {
        AdHocFilter(key: key, op: .equals, value: value)
    }

    private func filter(_ key: String, _ op: AdHocFilter.Op, _ value: String) -> AdHocFilter {
        AdHocFilter(key: key, op: op, value: value)
    }

    private func apply(_ filters: [AdHocFilter], _ query: String) -> String {
        QueryRewriter.applying(filters, to: query)
    }

    // MARK: - The shapes the daemon accepts

    @Test("a bare metric gains a matcher block")
    func bareMetric() {
        #expect(apply([filter("project", "toki")], "sum(toki_tokens_total[1h]) by (model)")
                == "sum(toki_tokens_total{project=\"toki\"}[1h]) by (model)")
    }

    @Test("an existing block is extended, not replaced")
    func existingBlock() {
        let out = apply([filter("project", "toki")],
                        "sum(usage{provider=\"codex\"}[1h])")
        #expect(out == "sum(usage{provider=\"codex\", project=\"toki\"}[1h])")
    }

    @Test("an empty block does not gain a leading comma")
    func emptyBlock() {
        #expect(apply([filter("project", "toki")], "usage{}[1h]")
                == "usage{project=\"toki\"}[1h]")
    }

    @Test("the standard PromQL form is handled too")
    func promQLForm() {
        let out = apply([filter("model", "opus")],
                        "sum by (project) (increase(toki_tokens_total[$__interval]))")
        #expect(out == "sum by (project) (increase(toki_tokens_total{model=\"opus\"}[$__interval]))")
    }

    @Test("every operator survives")
    func operators() {
        #expect(apply([filter("m", .notEquals, "x")], "usage").contains("m!=\"x\""))
        #expect(apply([filter("m", .matches, "a.*")], "usage").contains("m=~\"a.*\""))
        #expect(apply([filter("m", .notMatches, "a.*")], "usage").contains("m!~\"a.*\""))
    }

    @Test("several filters are comma separated")
    func severalFilters() {
        let out = apply([filter("a", "1"), filter("b", "2")], "usage[1h]")
        #expect(out == "usage{a=\"1\", b=\"2\"}[1h]")
    }

    // MARK: - What must never be mistaken for the selector

    /// The one that produces a valid-but-wrong query if the rewrite is naive:
    /// a filter VALUE that reads like a metric name.
    @Test("a metric name inside a filter value is not the selector")
    func metricNameInsideAValue() {
        let out = apply([filter("model", "opus")], "sum(cost{project=\"usage\"}[1h])")
        #expect(out == "sum(cost{project=\"usage\", model=\"opus\"}[1h])")
    }

    @Test("a longer identifier that merely starts with a metric name is skipped")
    func identifierPrefix() {
        let out = apply([filter("a", "1")], "sum(usage_total[1h])")
        #expect(out == "sum(usage_total[1h])", "usage_total is not a metric this parser knows")
    }

    @Test("a brace that is not the metric's own is left alone")
    func unrelatedBrace() {
        let out = apply([filter("a", "1")], "sum(usage[1h]) by (model) {not_a_selector}")
        #expect(out == "sum(usage{a=\"1\"}[1h]) by (model) {not_a_selector}")
    }

    // MARK: - Refusing to guess

    /// A filter that quietly does not apply is bad. A query mangled into
    /// something that still parses is worse.
    @Test("an unrecognised query is returned untouched")
    func unrecognisedQueryUntouched() {
        #expect(apply([filter("a", "1")], "totally_unknown_metric[1h]")
                == "totally_unknown_metric[1h]")
        #expect(apply([filter("a", "1")], "") == "")
    }

    @Test("an unterminated brace is not repaired by the rewriter")
    func unterminatedBrace() {
        // The reader's own syntax error must stay theirs, not become ours.
        #expect(apply([filter("a", "1")], "usage{project=\"toki\"") == "usage{project=\"toki\"")
    }

    @Test("no filters means no rewrite at all")
    func noFilters() {
        #expect(apply([], "sum(usage[1h])") == "sum(usage[1h])")
        #expect(apply([filter("", "x")], "sum(usage[1h])") == "sum(usage[1h])",
                "a half-typed filter with no key is not yet a filter")
    }

    // MARK: - Encoding

    /// A value containing a quote must not close the string early and turn the
    /// rest of the query into syntax.
    @Test("quotes and backslashes in a value are escaped")
    func valueEscaping() {
        #expect(filter("k", "a\"b").encoded == "k=\"a\\\"b\"")
        #expect(filter("k", "a\\b").encoded == "k=\"a\\\\b\"")
    }

    @Test("a rewritten query keeps its quoting balanced")
    func balancedQuotes() {
        let out = apply([filter("k", "a\"b")], "usage[1h]")
        #expect(out.filter { $0 == "\"" }.count == 3, "two delimiters plus one escaped")
        #expect(out == "usage{k=\"a\\\"b\"}[1h]")
    }

    // MARK: - Idempotence of the surrounding query

    @Test("applying to an already-filtered query only adds")
    func repeatedApplicationAdds() {
        let once = apply([filter("a", "1")], "usage[1h]")
        let twice = apply([filter("b", "2")], once)
        #expect(twice == "usage{a=\"1\", b=\"2\"}[1h]")
    }
}
