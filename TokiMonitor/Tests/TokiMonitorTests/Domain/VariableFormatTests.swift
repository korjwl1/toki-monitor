import Testing
import Foundation
@testable import TokiMonitor

/// One join for every purpose is wrong for half of them. `model|project` is
/// right inside a `=~` matcher and meaningless inside `by (...)`, so a
/// multi-select variable could be used in exactly one position and a groupBy
/// could not exist at all.
@Suite("Variable formats")
struct VariableFormatTests {

    private func multi(_ name: String, _ values: [String],
                       kind: String = BuiltinVariablePluginKind.staticList) -> DashboardVariable {
        var v = DashboardVariable(name: name, type: .custom)
        v.multi = true
        v.plugin = VariablePluginRef(kind: kind, spec: Data())
        v.current = VariableSelection(text: values, value: values)
        return v
    }

    private func interpolate(_ template: String, _ vars: [DashboardVariable]) -> String {
        VariableResolver.interpolate(template: template, time: TimeConfig(), variables: vars)
    }

    // MARK: - The formats

    @Test("each format writes the selection the way its position needs")
    func formatsWriteTheirPosition() {
        let v = multi("m", ["a", "b"])
        #expect(interpolate("${m:csv}", [v]) == "a,b")
        #expect(interpolate("${m:pipe}", [v]) == "a|b")
        #expect(interpolate("${m:singlequote}", [v]) == "'a','b'")
        #expect(interpolate("${m:doublequote}", [v]) == "\"a\",\"b\"")
        #expect(interpolate("${m:raw}", [v]) == "a, b")
    }

    /// A model name contains dots. Alternating them unescaped inside `=~`
    /// silently matches more series than the reader selected.
    @Test("regex format escapes each value")
    func regexEscapes() {
        let v = multi("m", ["gpt-5.6", "claude+x"])
        #expect(interpolate("${m:regex}", [v]) == #"gpt-5\.6|claude\+x"#)
    }

    @Test("an unknown format falls back to the variable's default, not to a syntax error")
    func unknownFormatFallsBack() {
        let v = multi("m", ["a", "b"])
        #expect(interpolate("${m:cvs}", [v]) == "a|b")
    }

    @Test("every occurrence is rewritten, each with its own format")
    func multipleOccurrences() {
        let v = multi("m", ["a", "b"])
        #expect(interpolate("x=${m:csv} y=${m:pipe}", [v]) == "x=a,b y=a|b")
    }

    // MARK: - Defaults follow meaning

    /// The whole point of the groupBy kind: its values are dimension names,
    /// so they join with commas without anyone writing a specifier.
    @Test("a groupBy joins with commas and everything else with alternation")
    func defaultsFollowMeaning() {
        let group = multi("g", ["model", "project"], kind: BuiltinVariablePluginKind.groupBy)
        #expect(interpolate("sum(x[1h]) by ($g)", [group]) == "sum(x[1h]) by (model,project)")

        let values = multi("m", ["opus", "gpt"])
        #expect(interpolate("x{model=~\"$m\"}", [values]) == "x{model=~\"opus|gpt\"}")
    }

    @Test("the braced form without a specifier keeps the default too")
    func bracedFormKeepsDefault() {
        let group = multi("g", ["model", "project"], kind: BuiltinVariablePluginKind.groupBy)
        #expect(interpolate("by (${g})", [group]) == "by (model,project)")
    }

    // MARK: - Selection edge cases

    /// `customAllValue` is already a finished expression; quoting or
    /// comma-joining it would break the query it was written for.
    @Test("All is written verbatim under any format")
    func allIsVerbatim() {
        var v = multi("m", ["$__all"])
        v.includeAll = true
        #expect(interpolate("${m:csv}", [v]) == ".*")
        #expect(interpolate("${m:doublequote}", [v]) == ".*")
    }

    @Test("a single-select variable answers with one value")
    func singleSelectStaysSingle() {
        var v = multi("m", ["a", "b"])
        v.multi = false
        #expect(interpolate("${m:csv}", [v]) == "a")
    }

    @Test("an empty selection interpolates to nothing rather than punctuation")
    func emptySelection() {
        let v = multi("m", [])
        #expect(interpolate("[${m:csv}]", [v]) == "[]")
    }

    /// `capturingRegexp` runs before the join, so the format sees the values
    /// the author meant to keep.
    @Test("the capturing regex applies before the format")
    func capturingRegexAppliesFirst() {
        var v = multi("m", ["prod-a", "prod-b"])
        v.capturingRegexp = "^prod-(.*)$"
        #expect(interpolate("${m:csv}", [v]) == "a,b")
    }

    /// A specifier on an identifier that shares a prefix must not be taken
    /// for this variable's.
    @Test("a longer identifier is not matched by a shorter variable's name")
    func wordBoundaryHolds() {
        let v = multi("m", ["a"])
        #expect(interpolate("${models:csv}", [v]) == "${models:csv}")
        #expect(interpolate("$models", [v]) == "$models")
    }
}
