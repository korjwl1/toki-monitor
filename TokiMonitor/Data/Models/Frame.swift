import Foundation

// MARK: - Frame — the dashboard's data contract
//
// Replaces `TimeSeriesData` as the shape that flows from a datasource to a
// panel. The difference that matters is not "more fields": it is that a series
// is identified by a NAMED LABEL MAP rather than by one string.
//
// The old contract had two axes — a period string and a `model` string — and
// fixed measure columns. Any third dimension was concatenated into the period
// (`"2026-08-10T00:00:00|toki_projects"`) and duplicated into `model`, so
// `by (model, project)` was unrecoverable, provider identity was dropped
// entirely, and nothing downstream could match a series by anything but its
// name. Transformations, per-series overrides, and `{{project}}` display names
// are all impossible without this.
//
// Deliberately NOT a copy of Grafana's DataFrame. Same core idea (columnar,
// typed fields, labels per field, provenance), but only the parts we can
// actually serve; adopting Grafana's full storage schema would repeat the
// dual-authority problem this is meant to end.

/// Column element type. Only what a toki result can actually contain.
enum FieldType: String, Codable, Sendable {
    case time
    case number
    case string
    case boolean
}

/// A typed column. Columnar rather than row-of-Any: values of one field share
/// a type, so readers never unbox per element and a transformation can reason
/// about a column without inspecting every row.
enum FieldValues: Equatable, Sendable {
    case time([Date])
    /// Optional because a series can be absent in a bucket — which is NOT the
    /// same as zero, and rendering the two identically is how a gap becomes a
    /// misleading dip to the axis.
    case number([Double?])
    case string([String?])
    case boolean([Bool?])

    var count: Int {
        switch self {
        case let .time(v): return v.count
        case let .number(v): return v.count
        case let .string(v): return v.count
        case let .boolean(v): return v.count
        }
    }

    var type: FieldType {
        switch self {
        case .time: return .time
        case .number: return .number
        case .string: return .string
        case .boolean: return .boolean
        }
    }

    /// Numeric view of the column, for readers that only handle numbers.
    /// Non-numeric columns yield nil rather than a coerced value.
    var numbers: [Double?]? {
        if case let .number(v) = self { return v }
        return nil
    }
}

/// One column of a frame.
struct Field: Equatable, Sendable {
    /// Column name — the measure ("total_tokens"), not the series.
    let name: String
    /// Series identity. `["provider": "codex", "project": "toki"]`. The whole
    /// point of the rewrite: identity is a map, so a consumer can match on one
    /// dimension without parsing a composite string.
    let labels: [String: String]
    let values: FieldValues

    var type: FieldType { values.type }

    init(name: String, labels: [String: String] = [:], values: FieldValues) {
        self.name = name
        self.labels = labels
        self.values = values
    }
}

/// Where a frame came from, so Inspect can answer "why does this number look
/// like that" without the user reading source.
struct FrameMeta: Equatable, Sendable {
    /// The query text actually sent, AFTER variable interpolation.
    var executedQuery: String?
    /// Datasource that served it.
    var datasource: String?
    /// Non-fatal problems: a dropped dimension, an unparsable row. These must
    /// be visible — silently returning fewer rows is how a wrong dashboard
    /// looks like a correct one.
    var notices: [String] = []
}

/// A columnar table. All fields have equal length.
struct Frame: Equatable, Sendable {
    /// Which query produced it. Needed before two queries can be joined, and
    /// the reason a panel can eventually hold more than query A.
    var refId: String
    /// Human-readable series name, derived from labels when not set.
    var name: String?
    var fields: [Field]
    var meta: FrameMeta

    init(refId: String, name: String? = nil, fields: [Field] = [], meta: FrameMeta = FrameMeta()) {
        self.refId = refId
        self.name = name
        self.fields = fields
        self.meta = meta
    }

    var rowCount: Int { fields.first?.values.count ?? 0 }

    /// The time column, if this frame has one.
    var timeField: Field? { fields.first { $0.type == .time } }

    /// Numeric columns, in declaration order.
    var numberFields: [Field] { fields.filter { $0.type == .number } }

    func field(named name: String) -> Field? { fields.first { $0.name == name } }

    /// Labels shared by every field — the frame's own identity. A field-level
    /// label that varies across fields is not part of it.
    var commonLabels: [String: String] {
        guard let first = fields.first else { return [:] }
        var shared = first.labels
        for f in fields.dropFirst() {
            shared = shared.filter { f.labels[$0.key] == $0.value }
        }
        return shared
    }

    /// A stable display name: explicit name, else the label map rendered in a
    /// deterministic order, else the refId.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        let labels = commonLabels
        if labels.isEmpty { return refId }
        // Sorted so the same series never renders under two different names.
        return labels.sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: " · ")
    }

    /// True when every field is the same length. A frame that violates this is
    /// a bug in whatever produced it, and readers index across columns freely.
    var isRectangular: Bool {
        guard let n = fields.first?.values.count else { return true }
        return fields.allSatisfy { $0.values.count == n }
    }
}

/// The result of executing a panel's queries. Keyed access by refId is what
/// makes joins and expressions possible later.
struct FrameSet: Equatable, Sendable {
    var frames: [Frame]
    /// Per-query failures. A failed query must not read as an empty result —
    /// that is how a broken dashboard looks like an idle one.
    var errors: [String: String]

    init(frames: [Frame] = [], errors: [String: String] = [:]) {
        self.frames = frames
        self.errors = errors
    }

    func frames(refId: String) -> [Frame] { frames.filter { $0.refId == refId } }

    var isEmpty: Bool { frames.allSatisfy { $0.rowCount == 0 } }

    /// Every notice raised while building this set, for Inspect.
    var notices: [String] { frames.flatMap(\.meta.notices) }
}
