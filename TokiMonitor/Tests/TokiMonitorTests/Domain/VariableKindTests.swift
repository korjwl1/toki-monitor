import Testing
import Foundation
@testable import TokiMonitor

/// Constant and text are the two kinds a dashboard needs before it can stop
/// repeating literals: a constant names one, a textbox lets the reader supply
/// one. Neither existed, so both had to be faked with a one-entry static list
/// — which the toolbar then rendered as a menu with nothing to choose.
@Suite("Constant and text variables")
struct ConstantAndTextVariableTests {

    private func context() -> VariableLoadContext {
        VariableLoadContext(time: TimeConfig(), resolvedVariables: [:], queryClient: nil)
    }

    private func variable(kind: String, spec: Data) -> DashboardVariable {
        DashboardVariable(name: "v", type: .custom,
                          plugin: VariablePluginRef(kind: kind, spec: spec))
    }

    // MARK: - Values

    @Test("a constant resolves to the author's value")
    func constantResolves() async throws {
        let spec = try JSONEncoder().encode(ConstantVariableSpec(value: "toki_projects"))
        let options = try await ConstantVariableLoader()
            .loadOptions(specData: spec, context: context())
        #expect(options.map(\.value) == ["toki_projects"])
    }

    @Test("a text variable offers the author's default")
    func textDefault() async throws {
        let spec = try JSONEncoder().encode(TextVariableSpec(value: "opus"))
        let options = try await TextVariableLoader()
            .loadOptions(specData: spec, context: context())
        #expect(options.map(\.value) == ["opus"])
    }

    /// An empty default is a real choice — "start blank" — and must not
    /// become an option showing an empty string in a menu.
    @Test("an empty value produces no option")
    func emptyValueIsNoOption() async throws {
        let spec = try JSONEncoder().encode(TextVariableSpec(value: ""))
        #expect(try await TextVariableLoader()
            .loadOptions(specData: spec, context: context()).isEmpty)
    }

    @Test("a corrupt spec does not throw")
    func corruptSpecIsEmpty() async throws {
        let junk = Data("not json".utf8)
        #expect(try await ConstantVariableLoader()
            .loadOptions(specData: junk, context: context()).isEmpty)
    }

    // MARK: - What the reader sees

    /// A constant is the author's, not the reader's. A toolbar control with
    /// exactly one unchangeable item is noise.
    @Test("a constant offers no toolbar control; every other kind does")
    func constantHasNoControl() {
        #expect(!variable(kind: BuiltinVariablePluginKind.constant, spec: Data())
            .isReaderControllable)
        #expect(variable(kind: BuiltinVariablePluginKind.text, spec: Data())
            .isReaderControllable)
        #expect(variable(kind: BuiltinVariablePluginKind.staticList, spec: Data())
            .isReaderControllable)
    }

    /// Pre-v4 dashboards carry no plugin ref at all.
    @Test("a variable with no plugin still names a kind")
    func legacyTypeMapsToAKind() {
        var v = DashboardVariable(name: "v", type: .interval)
        #expect(v.effectivePluginKind == BuiltinVariablePluginKind.interval)
        v.type = .custom
        #expect(v.effectivePluginKind == BuiltinVariablePluginKind.staticList)
        #expect(v.isReaderControllable, "a legacy variable is never a constant")
    }

    // MARK: - Interpolation

    /// The point of both kinds: `$name` in a panel query becomes the value.
    @Test("both kinds interpolate into a query")
    func interpolatesIntoQuery() {
        var v = DashboardVariable(name: "project", type: .custom)
        v.current = VariableSelection(text: ["toki"], value: ["toki"])
        let out = VariableResolver.interpolate(
            template: "sum(tokens{project=\"$project\"})",
            time: TimeConfig(), variables: [v]
        )
        #expect(out == "sum(tokens{project=\"toki\"})")
    }

    /// A reader typing `a|b` into a textbox must reach the query as written,
    /// not as a regex template the substitution reinterprets.
    @Test("typed text with regex metacharacters survives substitution")
    func typedTextIsEscaped() {
        var v = DashboardVariable(name: "q", type: .custom)
        v.current = VariableSelection(text: ["a|b"], value: ["a|b"])
        let out = VariableResolver.interpolate(template: "x{m=~\"$q\"}",
                                               time: TimeConfig(), variables: [v])
        #expect(out == "x{m=~\"a|b\"}")
    }
}
