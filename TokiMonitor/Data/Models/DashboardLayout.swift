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

/// JSON Pointer reference (`{"$ref": "#/spec/panels/<key>"}`). Encoded with
/// the literal `$ref` key, decoded back to a typed value.
struct JSONRef: Codable, Equatable, Sendable {
    var ref: String

    init(panelKey: String) {
        self.ref = "#/spec/panels/\(panelKey)"
    }

    init(ref: String) { self.ref = ref }

    enum CodingKeys: String, CodingKey {
        case ref = "$ref"
    }

    /// Extract the panel map key from the ref string, if it points to a
    /// panel under `#/spec/panels/`.
    var panelKey: String? {
        let prefix = "#/spec/panels/"
        guard ref.hasPrefix(prefix) else { return nil }
        return String(ref.dropFirst(prefix.count))
    }
}
