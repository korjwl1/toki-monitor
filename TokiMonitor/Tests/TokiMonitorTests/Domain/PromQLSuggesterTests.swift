import Testing
import Foundation
@testable import TokiMonitor

/// The suggester's whole justification is that neither backend is a real
/// PromQL engine, so it must offer only what the active one accepts. It was
/// offering `rate`, `max`, `min` and `$__rate_interval`, which neither
/// implements and neither reports — the query then returns a plausible number
/// computed from a different expression than the one on screen.
@Suite("PromQL suggestions match the backend")
struct PromQLSuggesterTests {

    private func texts(_ query: String,
                       _ dialect: PromQLSuggester.Dialect) -> [String] {
        PromQLSuggester.suggestions(for: query, dialect: dialect).items.map(\.text)
    }

    // MARK: - Nothing unimplemented is offered

    @Test("functions no backend implements are gone")
    func unimplementedFunctionsAreGone() {
        for dialect in [PromQLSuggester.Dialect.local, .server] {
            let all = PromQLSuggester.all(dialect).map(\.text)
            #expect(!all.contains("rate"))
            #expect(!all.contains("max"))
            #expect(!all.contains("min"))
            #expect(!all.contains("$__rate_interval"))
        }
    }

    /// The one that made the omission visible: typing `ra` used to complete to
    /// `rate`.
    @Test("typing a prefix of a removed function suggests nothing")
    func removedPrefixSuggestsNothing() {
        #expect(texts("sum(usage[1h]) ra", .local).isEmpty)
    }

    // MARK: - Each dialect offers what it parses

    /// The local parser has these; the server's has no branch for them and
    /// falls through to `usage`, which would answer a different question
    /// without saying so.
    @Test("local-only vocabulary is offered locally and withheld from the server")
    func localOnlyVocabulary() {
        for text in ["windows", "sessions", "projects", "avg", "count", "offset"] {
            #expect(PromQLSuggester.all(.local).map(\.text).contains(text),
                    "local should offer \(text)")
            #expect(!PromQLSuggester.all(.server).map(\.text).contains(text),
                    "server should not offer \(text)")
        }
    }

    @Test("what both backends honour is offered in both")
    func sharedVocabulary() {
        for text in ["usage", "cost", "events", "sum", "increase", "by",
                     "$__interval", "$provider"] {
            #expect(PromQLSuggester.all(.local).map(\.text).contains(text))
            #expect(PromQLSuggester.all(.server).map(\.text).contains(text))
        }
    }

    @Test("the starter set is metrics and functions, per dialect")
    func starterSet() {
        let local = texts("", .local)
        #expect(local.contains("windows"))
        #expect(!local.contains("model"), "labels are not a way to start a query")
        #expect(!texts("", .server).contains("windows"))
    }

    // MARK: - Tokenizing is unchanged

    @Test("suggestions match the token being typed, case-insensitively")
    func prefixMatching() {
        #expect(texts("sum(us", .local) == ["usage"])
        #expect(texts("SUM(US", .local) == ["usage"])
        #expect(!texts("sum(usage", .local).contains("usage"),
                "an exact match is not a suggestion")
    }

    @Test("accepting a suggestion replaces only the active token")
    func applyReplacesToken() {
        let suggestion = PromQLSuggestion(text: "usage", kind: .metric, hint: nil)
        #expect(PromQLSuggester.apply(suggestion, to: "sum(us") == "sum(usage ")
        let range = PromQLSuggestion(text: "[1h]", kind: .rangeVector, hint: nil)
        #expect(PromQLSuggester.apply(range, to: "usage[1") == "usage[1h]",
                "a range vector keeps the cursor tight")
    }
}
