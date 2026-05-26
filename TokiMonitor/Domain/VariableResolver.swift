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
        let providerValues = value(named: "provider", in: variables)
        let provider = providerValues
            .filter { !$0.isEmpty && $0 != "All" && $0 != "all" && $0 != "$__all" }
            .first(where: { ["claude_code", "codex"].contains($0) })
        if let provider {
            query = query.replacingOccurrences(of: "$provider", with: "provider=\"\(provider)\"")
        } else {
            query = query.replacingOccurrences(of: ", $provider", with: "")
            query = query.replacingOccurrences(of: "$provider", with: "")
        }

        // Generic interpolation — precompile bare-form regex per variable.
        struct Compiled {
            let variable: DashboardVariable
            let value: String
            let bareForm: NSRegularExpression?
        }
        let compiled: [Compiled] = variables
            .filter { $0.name != "provider" }
            .map { v in
                let escaped = NSRegularExpression.escapedPattern(for: v.name)
                let pattern = "\\$\(escaped)(?![A-Za-z0-9_])"
                return Compiled(
                    variable: v,
                    value: interpolatedValue(for: v),
                    bareForm: try? NSRegularExpression(pattern: pattern)
                )
            }

        for _ in 0..<4 {
            let before = query
            for c in compiled {
                query = query.replacingOccurrences(of: "${\(c.variable.name)}", with: c.value)
                if let regex = c.bareForm {
                    let range = NSRange(query.startIndex..., in: query)
                    query = regex.stringByReplacingMatches(
                        in: query, range: range,
                        withTemplate: NSRegularExpression.escapedTemplate(for: c.value)
                    )
                }
            }
            if query == before { break }
        }

        return query
    }

    /// Current selection for a variable by name (empty array if not found).
    static func value(named name: String, in variables: [DashboardVariable]) -> [String] {
        variables.first(where: { $0.name == name })?.current.value ?? []
    }

    /// Resolve one variable to the string that replaces `$name` /
    /// `${name}`. Honors multi-select (joined as PromQL regex
    /// alternation), the "All" sentinel (→ `customAllValue`), and the
    /// optional `capturingRegexp` post-filter.
    static func interpolatedValue(for variable: DashboardVariable) -> String {
        let selection = variable.current.value
        if variable.includeAll && (selection.contains("$__all") || selection.isEmpty) {
            return variable.effectiveCustomAllValue
        }

        let filtered = selection.filter { !$0.isEmpty && $0 != "$__all" }
        if filtered.isEmpty { return "" }

        let values: [String]
        if let pattern = variable.capturingRegexp, !pattern.isEmpty,
           let regex = try? NSRegularExpression(pattern: pattern) {
            values = filtered.map { raw in
                let range = NSRange(raw.startIndex..., in: raw)
                guard let m = regex.firstMatch(in: raw, range: range),
                      m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: raw)
                else { return raw }
                return String(raw[r])
            }
        } else {
            values = filtered
        }

        if variable.multi && values.count > 1 {
            return values.joined(separator: "|")
        }
        return values.first ?? ""
    }
}
