import Foundation
@testable import TokiMonitor

// MARK: - Every string the plan-fit page can draw
//
// Several claims about this page are claims about ALL of its text: nothing
// compares the reader with anyone (FR-050), no verdict names a tier or a price
// (V7), no monetary figure appears without "at current prices" (FR-045). A
// test that lists the fields it checks holds only until someone adds a field —
// and the sections were added one at a time, so that is not hypothetical.
//
// So this walks the model with `Mirror` instead. A new section, a new note, a
// new caption is audited the moment it is added, with no test edited. The
// recursion follows structs, enums with payloads, arrays, dictionaries and
// optionals, which between them cover every shape in `PlanFitModel`.

enum PlanFitModelText {

    /// Every string reachable from a value, in document-ish order.
    static func every(of value: Any) -> [String] {
        var out: [String] = []
        collect(value, into: &out, depth: 0)
        return out
    }

    /// Depth is bounded because `Mirror` will happily follow a reference cycle
    /// forever; the model is a tree about six levels deep, so twelve is slack
    /// rather than a limit anything real reaches.
    private static let maximumDepth = 12

    private static func collect(_ value: Any, into out: inout [String], depth: Int) {
        guard depth <= maximumDepth else { return }

        if let text = value as? String {
            if !text.isEmpty { out.append(text) }
            return
        }
        // Anything else that is not a container contributes nothing: numbers,
        // colours and dates reach the screen through a String produced above.
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle != nil else { return }
        for child in mirror.children {
            collect(child.value, into: &out, depth: depth + 1)
        }
    }

    /// The strings, joined — for the assertions that are about the page as one
    /// document rather than about any single field.
    static func joined(of value: Any) -> String {
        every(of: value).joined(separator: "\n")
    }
}
