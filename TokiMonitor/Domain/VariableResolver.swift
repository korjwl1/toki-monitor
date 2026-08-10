import Foundation

/// Stateless variable interpolation utilities.
///
/// Was previously embedded in `DashboardViewModel` as `interpolateQuery` /
/// `interpolatedValue`. Both functions only read the templating list +
/// time config and return a string — no view state, no actor isolation.
/// Moving them to a Domain helper trims the VM and makes the
/// interpolation pure and testable.
enum VariableResolver {

    /// Replace `$__interval`, `$provider`, `${name}`, and `$name` in
    /// `template` against the dashboard's variable values.
    ///
    /// - `$__interval` expands to `time.bucketString`.
    /// - `$provider` expands to a label-matcher snippet (`provider="X"`)
    ///   *only* for the known provider ids `claude_code` / `codex`; any
    ///   "All" or unknown selection drops the whole `, $provider` chunk
    ///   so the query stays valid PromQL.
    /// - Generic `${name}` / `$name` substitutions are cascaded up to a
    ///   fixed point (4 iterations) so a variable can reference another
    ///   variable's value. Regex template metas in the substituted value
    ///   are escaped so `$1` or `\` in a value don't get reinterpreted.
    static func interpolate(
        template: String,
        time: TimeConfig,
        variables: [DashboardVariable]
    ) -> String {
        var query = template
        query = query.replacingOccurrences(of: "$__interval", with: time.bucketString)

        // Provider — special-cased: expands to `provider="X"` so panel
        // templates can write `usage{$provider}` and get valid PromQL.
        // Uses a word-boundary regex so `$providerExtra` (or any
        // identifier sharing the `$provider` prefix) is not partially
        // matched — `replacingOccurrences(of:)` has no concept of token
        // boundaries and would corrupt the longer identifier.
        let providerValues = value(named: "provider", in: variables)
        let provider = providerValues
            .filter { !$0.isEmpty && $0 != "All" && $0 != "all" && $0 != "$__all" }
            .first(where: { ["claude_code", "codex"].contains($0) })
        let providerBoundary = try? NSRegularExpression(pattern: "\\$provider(?![A-Za-z0-9_])")
        if let provider, let regex = providerBoundary {
            let replacement = NSRegularExpression.escapedTemplate(for: "provider=\"\(provider)\"")
            let range = NSRange(query.startIndex..., in: query)
            query = regex.stringByReplacingMatches(in: query, range: range, withTemplate: replacement)
        } else if let regex = providerBoundary {
            // `, $provider` cleanup keeps a literal-string pass since the
            // surrounding comma+space is what we are stripping, not the
            // identifier alone.
            query = query.replacingOccurrences(of: ", $provider", with: "")
            let range = NSRange(query.startIndex..., in: query)
            query = regex.stringByReplacingMatches(in: query, range: range, withTemplate: "")
        }

        // Generic interpolation — precompile bare-form regex per variable.
        struct Compiled {
            let variable: DashboardVariable
            let value: String
            let bareForm: NSRegularExpression?
            /// `${name:format}` — matched before the bare and braced forms so
            /// the specifier is consumed rather than left dangling as text.
            let formatted: NSRegularExpression?
        }
        let compiled: [Compiled] = variables
            .filter { $0.name != "provider" }
            .map { v in
                let escaped = NSRegularExpression.escapedPattern(for: v.name)
                let pattern = "\\$\(escaped)(?![A-Za-z0-9_])"
                return Compiled(
                    variable: v,
                    value: interpolatedValue(for: v),
                    bareForm: try? NSRegularExpression(pattern: pattern),
                    formatted: try? NSRegularExpression(
                        pattern: "\\$\\{\(escaped):([A-Za-z]+)\\}"
                    )
                )
            }

        // Fixed-point interpolation with cycle bound. 4 passes is enough
        // for any normal dashboard ($a → $b → $c → $d → final). If the
        // template still mutates at the final iteration, there's a
        // cycle (e.g. $a contains "$b" and $b contains "$a"); we log
        // and return the current state rather than spinning forever or
        // truncating silently.
        let maxIterations = 4
        var converged = false
        for i in 0..<maxIterations {
            let before = query
            for c in compiled {
                if let regex = c.formatted {
                    query = replaceFormatted(in: query, regex: regex, variable: c.variable)
                }
                query = query.replacingOccurrences(of: "${\(c.variable.name)}", with: c.value)
                if let regex = c.bareForm {
                    let range = NSRange(query.startIndex..., in: query)
                    query = regex.stringByReplacingMatches(
                        in: query, range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: c.value)
                    )
                }
            }
            if query == before {
                converged = true
                break
            }
            if i == maxIterations - 1 {
                #if DEBUG
                print("[VariableResolver] interpolation did not converge in \(maxIterations) passes — possible variable cycle. Template: \(template)")
                #endif
            }
        }
        _ = converged
        return query
    }

    /// Current selection for a variable by name (empty array if not found).
    static func value(named name: String, in variables: [DashboardVariable]) -> [String] {
        variables.first(where: { $0.name == name })?.current.value ?? []
    }

    /// Rewrite every `${name:format}` occurrence, one at a time because each
    /// may name a different format.
    ///
    /// An unrecognised format falls back to the variable's own default rather
    /// than being left in the query: `${m:cvs}` should draw the wrong data at
    /// worst, not produce a syntax error that hides the typo behind a parser
    /// message about a brace.
    private static func replaceFormatted(
        in query: String, regex: NSRegularExpression, variable: DashboardVariable
    ) -> String {
        var out = query
        while true {
            let range = NSRange(out.startIndex..., in: out)
            guard let match = regex.firstMatch(in: out, range: range),
                  let whole = Range(match.range, in: out),
                  match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: out)
            else { return out }
            let format = VariableFormat(rawValue: String(out[nameRange]).lowercased())
            out.replaceSubrange(whole, with: interpolatedValue(for: variable, format: format))
        }
    }

    /// Resolve one variable to the string that replaces `$name` /
    /// `${name}` / `${name:format}`. Honors multi-select, the "All" sentinel
    /// (→ `customAllValue`), and the optional `capturingRegexp` post-filter.
    ///
    /// `format` nil means "the variable's own default", which follows from
    /// what it means: a groupBy holds dimension names and joins with commas,
    /// everything else holds values and joins as regex alternation.
    ///
    /// "All" is returned verbatim and no format is applied to it:
    /// `customAllValue` is already a finished expression (`.*` by default),
    /// and quoting or comma-joining it would break the query it was written
    /// for.
    static func interpolatedValue(for variable: DashboardVariable,
                                  format: VariableFormat? = nil) -> String {
        let selection = variable.current.value
        if variable.includeAll && (selection.contains("$__all") || selection.isEmpty) {
            return variable.effectiveCustomAllValue
        }

        var values = selectedValues(for: variable)
        if values.isEmpty { return "" }
        // A single-select variable answers with one value even if several are
        // somehow stored — the same guarantee this made before formats existed.
        if !variable.multi, let first = values.first { values = [first] }

        return (format ?? variable.defaultFormat).apply(values)
    }

    /// The selection with sentinels dropped and `capturingRegexp` applied.
    static func selectedValues(for variable: DashboardVariable) -> [String] {
        let filtered = variable.current.value.filter { !$0.isEmpty && $0 != "$__all" }
        guard let pattern = variable.capturingRegexp, !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern)
        else { return filtered }
        return filtered.map { raw in
            let range = NSRange(raw.startIndex..., in: raw)
            guard let m = regex.firstMatch(in: raw, range: range),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: raw)
            else { return raw }
            return String(raw[r])
        }
    }
}
