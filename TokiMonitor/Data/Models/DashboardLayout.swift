import Foundation

/// Perses-style layout container. Mirrors `Grid` from Perses; carries
/// `items[]` that point to panels in the dashboard's `panels` map via JSON
/// Pointer (`$ref`).
///
/// The on-disk JSON form is Perses-compatible; in-memory we still drive the
/// renderer from `PanelConfig.gridPosition`. Layouts are reconstructed on
/// encode and decomposed on decode so round-trips are lossless.
struct DashboardLayout: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var kind: String = "Grid"
    var spec: GridLayoutSpec

    enum CodingKeys: String, CodingKey {
        case kind, spec
    }
}

struct GridLayoutSpec: Codable, Equatable, Sendable {
    var display: GridDisplay?
    var items: [LayoutGridItem] = []
}

struct GridDisplay: Codable, Equatable, Sendable {
    var title: String?
    var collapse: CollapseSpec?
}

struct CollapseSpec: Codable, Equatable, Sendable {
    var open: Bool = true
}

struct LayoutGridItem: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// Reference to a panel in the dashboard's `panels` map.
    var content: JSONRef
}

/// Reference to a panel by id.
///
/// The serialized form `{"$ref": "#/spec/panels/<uuid>"}` is *shaped* like
/// a JSON Pointer (RFC 6901) so the on-disk layout looks Perses-style,
/// but the path does not resolve against our actual JSON tree — our
/// `panels` field is an *array*, not a map keyed by uuid. We don't
/// promise Perses interoperability (one-way export was dropped), so the
/// pointer here is effectively an opaque "panel id" sentinel that we
/// resolve in `DashboardCustomLayout` via `panelKey`. Keeping the same
/// on-disk shape lets old configs decode without migration.
struct JSONRef: Codable, Equatable, Sendable {
    var ref: String

    init(panelKey: String) {
        self.ref = "#/spec/panels/\(panelKey)"
    }

    init(ref: String) { self.ref = ref }

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }

    /// Extract the panel id from the ref string.
    var panelKey: String? {
        let prefix = "#/spec/panels/"
        guard ref.hasPrefix(prefix) else { return nil }
        return String(ref.dropFirst(prefix.count))
    }
}
