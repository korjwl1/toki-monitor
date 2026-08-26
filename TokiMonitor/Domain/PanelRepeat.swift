import Foundation

// MARK: - One panel per value
//
// A dashboard about six projects should not contain the same chart six times.
// The author writes it once, points `repeat` at a multi-value variable, and
// the reader's selection decides how many panels there are (contract US4).
//
// Expansion happens on the way to the screen and never on the way to disk. The
// stored dashboard keeps one panel with a `repeat` on it; what the grid draws
// and what the fetch layer queries are both this function's output. Writing
// the expansion back would freeze one moment's variable selection into the
// document, and the next reader would inherit somebody else's filter as if it
// were the design.
enum PanelRepeat {

    /// Expand every panel that repeats, in row order.
    ///
    /// A panel whose `repeat` names a variable that does not exist, or one
    /// whose variable currently has no values, is returned **as itself** — one
    /// panel, unchanged. Anything else means a panel silently disappears from
    /// a dashboard because of a variable the reader may not even be able to
    /// see, and a missing panel is not a message: nobody can tell it from a
    /// panel that was never there.
    static func expand(_ panels: [PanelConfig],
                       variables: [DashboardVariable]) -> [PanelConfig] {
        let byName = Dictionary(variables.map { ($0.name, $0) },
                                uniquingKeysWith: { first, _ in first })
        var out: [PanelConfig] = []
        // Rows the expansions above this panel have taken that the stored
        // layout did not budget for. Without it, a panel that grows from one
        // copy to three draws on top of whatever was underneath it.
        var rowShift = 0

        for panel in panels.sorted(by: { $0.gridPosition.row < $1.gridPosition.row }) {
            var shifted = panel
            shifted.gridPosition.row += rowShift

            guard let name = panel.repeat, !name.isEmpty,
                  let variable = byName[name]
            else {
                out.append(shifted)
                continue
            }
            let values = VariableResolver.repeatValues(for: variable)
            guard !values.isEmpty else {
                out.append(shifted)
                continue
            }

            let placed = positions(for: shifted.gridPosition,
                                   count: values.count,
                                   direction: panel.repeatDirection ?? .horizontal)
            for (index, value) in values.enumerated() {
                var copy = instance(of: shifted, variable: variable, value: value,
                                    isFirst: index == 0)
                copy.gridPosition = placed.frames[index]
                out.append(copy)
            }
            rowShift += placed.extraRows
        }
        return out
    }

    // MARK: - One instance

    /// One expanded panel: the value substituted into its title and its
    /// queries, and an identity that is stable across refreshes.
    static func instance(of panel: PanelConfig,
                         variable: DashboardVariable,
                         value: String,
                         isFirst: Bool) -> PanelConfig {
        var copy = panel
        copy.repeatedValue = value
        // The first copy keeps the stored panel's id and identity. Everything
        // that acts on a panel by id — drag, resize, edit, delete, the fetch
        // result map — then still reaches the definition through it, and the
        // reader is not looking at a row of panels none of which can be moved.
        if !isFirst {
            copy.id = instanceID(of: panel.id, value: value)
            copy.repeatSourceID = panel.id
        }
        copy.title = title(panel.title, variable: variable, value: value)
        copy.targets = panel.targets.map { target in
            var t = target
            t.query = target.query.map {
                VariableResolver.substituting(variable, value: value, in: $0)
            }
            return t
        }
        copy.queries = panel.queries.map { queries in
            queries.map { substituted($0, variable: variable, value: value) }
        }
        return copy
    }

    /// The title with the value in it.
    ///
    /// An author who wrote `$project` in the title gets it where they put it.
    /// One who did not still needs to tell six identical panels apart, so the
    /// value is appended rather than left off.
    static func title(_ title: String,
                      variable: DashboardVariable,
                      value: String) -> String {
        let substituted = VariableResolver.substituting(variable, value: value, in: title)
        if substituted != title { return substituted }
        return title.isEmpty ? value : "\(title) · \(value)"
    }

    private static func substituted(_ query: Query,
                                    variable: DashboardVariable,
                                    value: String) -> Query {
        guard query.spec.plugin.kind == BuiltinQueryPluginKind.tokiPromQLQuery,
              var spec = try? JSONDecoder().decode(TokiPromQLQuerySpec.self,
                                                   from: query.spec.plugin.spec),
              let text = spec.query
        else { return query }
        spec.query = VariableResolver.substituting(variable, value: value, in: text)
        guard let data = try? JSONEncoder().encode(spec) else { return query }
        var out = query
        out.spec.plugin.spec = data
        return out
    }

    // MARK: - Identity

    /// A stable id for the copy of `base` that draws `value`.
    ///
    /// Stable is the whole requirement: the fetch results, the loading state
    /// and SwiftUI's view identity are all keyed by panel id, so an id that
    /// changed between two refreshes would restart every animation and throw
    /// away every result on each pass. Derived from the pair rather than
    /// random, and derived rather than stored, because the set of values is
    /// the reader's live selection.
    static func instanceID(of base: UUID, value: String) -> UUID {
        var bytes = withUnsafeBytes(of: base.uuid) { Array($0) }
        // FNV-1a over the value. Not a hash with any security claim — it needs
        // to be the same number on every run, which `Hasher` explicitly is not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(value.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        for i in 0..<8 {
            bytes[8 + i] ^= UInt8(truncatingIfNeeded: hash >> (8 * UInt64(i)))
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Layout

    /// The grid is 24 columns wide, as everywhere else in the dashboard.
    static let columnCount = 24

    struct Placement: Equatable {
        /// One frame per copy, in value order.
        var frames: [GridPosition]
        /// Rows this expansion took beyond the one panel's own height, which
        /// everything below it has to move down by.
        var extraRows: Int
    }

    /// Where the copies go.
    ///
    /// Horizontal runs them rightwards from the original's own column and wraps
    /// to a new band when the next one would cross the right edge — a panel
    /// placed in the right half of the grid stays in the right half rather than
    /// jumping to column 0 the moment it gains a second copy. Vertical stacks
    /// them straight down.
    static func positions(for origin: GridPosition,
                          count: Int,
                          direction: RepeatDirection) -> Placement {
        guard count > 1 else { return Placement(frames: [origin], extraRows: 0) }
        let width = max(1, min(origin.width, columnCount))
        let height = max(1, origin.height)

        if direction == .vertical {
            let frames = (0..<count).map { index in
                GridPosition(column: origin.column, row: origin.row + index * height,
                             width: width, height: height)
            }
            return Placement(frames: frames, extraRows: (count - 1) * height)
        }

        let startColumn = min(max(0, origin.column), columnCount - width)
        var frames: [GridPosition] = []
        var column = startColumn
        var band = 0
        for _ in 0..<count {
            if column + width > columnCount {
                band += 1
                column = startColumn
            }
            frames.append(GridPosition(column: column, row: origin.row + band * height,
                                       width: width, height: height))
            column += width
        }
        return Placement(frames: frames, extraRows: band * height)
    }
}
