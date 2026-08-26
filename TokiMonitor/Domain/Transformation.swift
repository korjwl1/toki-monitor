import Foundation

// MARK: - Transformations
//
// `FrameSet -> FrameSet`, applied in order. This is the half of Grafana's
// freedom that does not come from the query language: the query stays simple
// and composition happens here. It is also what lets `PanelMetric` stop being
// an execution concern — a ratio like cacheHitRate is a query plus a
// `calculateField`, not a hardcoded enum case with a hardcoded renderer branch.
//
// Deliberately small. Grafana ships 40+; these are the ones toki's own data
// actually needs, and each earns its place by removing a special case that
// exists today.

/// One step in a panel's pipeline.
protocol Transformation: Sendable {
    /// Stable identifier, persisted in the dashboard JSON.
    static var id: String { get }
    func apply(_ input: FrameSet) -> FrameSet
}

// MARK: - Reduce

/// Collapse each numeric field to a single value.
///
/// Required before stat and gauge panels can be field-driven: today they read
/// a hardcoded aggregate off `TimeSeriesData`, so "which number does this card
/// show" is a renderer decision the user cannot see or change. Making it an
/// explicit reducer moves that decision into the panel definition.
struct ReduceTransformation: Transformation, Codable, Equatable {
    static let id = "reduce"

    enum Reducer: String, Codable, CaseIterable, Sendable {
        case last, lastNotNull, first, firstNotNull
        case sum, mean, min, max, count

        var displayName: String {
            switch self {
            case .last:         return L.tr("마지막", "Last")
            case .lastNotNull:  return L.tr("마지막(빈 값 제외)", "Last (not null)")
            case .first:        return L.tr("처음", "First")
            case .firstNotNull: return L.tr("처음(빈 값 제외)", "First (not null)")
            case .sum:          return L.tr("합계", "Sum")
            case .mean:         return L.tr("평균", "Mean")
            case .min:          return L.tr("최소", "Min")
            case .max:          return L.tr("최대", "Max")
            case .count:        return L.tr("개수", "Count")
            }
        }
    }

    var reducer: Reducer = .lastNotNull

    func apply(_ input: FrameSet) -> FrameSet {
        var out = input
        out.frames = input.frames.map { frame in
            var reduced = frame
            reduced.fields = frame.fields.compactMap { field in
                // The time column has no meaningful reduction; dropping it is
                // what turns a series into a single row.
                guard case let .number(values) = field.values else { return nil }
                return Field(name: field.name, labels: field.labels,
                             values: .number([Self.reduce(values, using: reducer)]))
            }
            return reduced
        }
        return out
    }

    /// nil propagates rather than becoming 0: a series with no data in the
    /// window is not a series that measured zero, and a stat card showing "0"
    /// for "nothing here" is a lie the user cannot detect.
    static func reduce(_ values: [Double?], using reducer: Reducer) -> Double? {
        let present = values.compactMap { $0 }
        switch reducer {
        case .last:         return values.last ?? nil
        case .lastNotNull:  return present.last
        case .first:        return values.first ?? nil
        case .firstNotNull: return present.first
        case .sum:          return present.isEmpty ? nil : present.reduce(0, +)
        case .mean:         return present.isEmpty ? nil : present.reduce(0, +) / Double(present.count)
        case .min:          return present.min()
        case .max:          return present.max()
        case .count:        return Double(present.count)
        }
    }
}

// MARK: - Calculate field

/// Add a field computed from two existing ones.
///
/// This is what makes ratios expressible without a new `PanelMetric` case.
/// `cacheHitRate` is `cache_read / (input + cache_read)` — the query language
/// has no binary operator, so today it is an enum entry with a bespoke
/// computation in the extractor.
struct CalculateFieldTransformation: Transformation, Codable, Equatable {
    static let id = "calculateField"

    enum Operation: String, Codable, CaseIterable, Sendable {
        case add, subtract, multiply, divide

        func callAsFunction(_ a: Double, _ b: Double) -> Double? {
            switch self {
            case .add: return a + b
            case .subtract: return a - b
            case .multiply: return a * b
            // Division by zero yields nil, not infinity: an infinite point
            // rescales an axis and hides every real value on the chart.
            case .divide: return b == 0 ? nil : a / b
            }
        }
    }

    var left: String
    var right: String
    var operation: Operation
    var alias: String?
    /// Drop the inputs, keeping only the result. Off by default — silently
    /// removing the user's own fields is surprising.
    var replaceFields: Bool = false

    func apply(_ input: FrameSet) -> FrameSet {
        var out = input
        out.frames = input.frames.map { frame in
            guard let l = frame.field(named: left)?.values.numbers,
                  let r = frame.field(named: right)?.values.numbers
            else {
                var f = frame
                f.meta.notices.append(
                    "calculateField: \(frame.field(named: left) == nil ? left : right) not found"
                )
                return f
            }
            let n = Swift.min(l.count, r.count)
            let computed: [Double?] = (0..<n).map { i in
                guard let a = l[i], let b = r[i] else { return nil }
                return operation(a, b)
            }
            let name = alias ?? "\(left) \(operation.rawValue) \(right)"
            var f = frame
            let field = Field(name: name, labels: frame.commonLabels, values: .number(computed))
            if replaceFields {
                f.fields = f.fields.filter { $0.type == .time } + [field]
            } else {
                f.fields.append(field)
            }
            return f
        }
        return out
    }
}

// MARK: - Organize

/// Rename, reorder and hide fields.
struct OrganizeTransformation: Transformation, Codable, Equatable {
    static let id = "organize"

    var excluded: Set<String> = []
    var renamed: [String: String] = [:]
    /// Field names in the order they should appear. Names not listed keep
    /// their relative order after the listed ones.
    var order: [String] = []

    func apply(_ input: FrameSet) -> FrameSet {
        var out = input
        out.frames = input.frames.map { frame in
            var kept = frame.fields.filter { !excluded.contains($0.name) }
            if !order.isEmpty {
                let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
                kept.sort { (rank[$0.name] ?? Int.max) < (rank[$1.name] ?? Int.max) }
            }
            var f = frame
            f.fields = kept.map { field in
                guard let newName = renamed[field.name] else { return field }
                return Field(name: newName, labels: field.labels, values: field.values)
            }
            return f
        }
        return out
    }
}

// MARK: - Filter by value

/// Drop rows where a field fails a predicate.
struct FilterByValueTransformation: Transformation, Codable, Equatable {
    static let id = "filterByValue"

    enum Comparison: String, Codable, CaseIterable, Sendable {
        case greater, greaterOrEqual, less, lessOrEqual, equal, notEqual

        func callAsFunction(_ a: Double, _ b: Double) -> Bool {
            switch self {
            case .greater: return a > b
            case .greaterOrEqual: return a >= b
            case .less: return a < b
            case .lessOrEqual: return a <= b
            case .equal: return a == b
            case .notEqual: return a != b
            }
        }
    }

    var field: String
    var comparison: Comparison
    var value: Double

    func apply(_ input: FrameSet) -> FrameSet {
        var out = input
        out.frames = input.frames.map { frame in
            guard let subject = frame.field(named: field)?.values.numbers else { return frame }
            // A null cannot satisfy a numeric comparison, so its row goes.
            let keep = subject.map { $0.map { comparison($0, value) } ?? false }
            return Self.selectRows(frame, keep: keep)
        }
        return out
    }

    /// Apply a row mask across every column, so the frame stays rectangular.
    static func selectRows(_ frame: Frame, keep: [Bool]) -> Frame {
        var f = frame
        f.fields = frame.fields.map { field in
            switch field.values {
            case let .time(v):
                return Field(name: field.name, labels: field.labels,
                             values: .time(zip(v, keep).filter(\.1).map(\.0)))
            case let .number(v):
                return Field(name: field.name, labels: field.labels,
                             values: .number(zip(v, keep).filter(\.1).map(\.0)))
            case let .string(v):
                return Field(name: field.name, labels: field.labels,
                             values: .string(zip(v, keep).filter(\.1).map(\.0)))
            case let .boolean(v):
                return Field(name: field.name, labels: field.labels,
                             values: .boolean(zip(v, keep).filter(\.1).map(\.0)))
            }
        }
        return f
    }
}

// MARK: - Sort and limit

/// Order frames by a reduced field. With `limit` this covers `topk`, which the
/// query language does not have.
struct SortByTransformation: Transformation, Codable, Equatable {
    static let id = "sortBy"

    var field: String
    var reducer: ReduceTransformation.Reducer = .sum
    var descending: Bool = true

    func apply(_ input: FrameSet) -> FrameSet {
        var out = input
        out.frames = input.frames.sorted { a, b in
            let x = a.field(named: field)?.values.numbers
                .flatMap { ReduceTransformation.reduce($0, using: reducer) }
            let y = b.field(named: field)?.values.numbers
                .flatMap { ReduceTransformation.reduce($0, using: reducer) }
            // Series with no value sort last either way, rather than jumping to
            // the top as a treated-as-zero.
            switch (x, y) {
            case let (l?, r?): return descending ? l > r : l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.displayName < b.displayName
            }
        }
        return out
    }
}

/// Keep the first N series.
struct LimitTransformation: Transformation, Codable, Equatable {
    static let id = "limit"

    var count: Int

    func apply(_ input: FrameSet) -> FrameSet {
        guard count >= 0 else { return input }
        var out = input
        let dropped = Swift.max(0, input.frames.count - count)
        out.frames = Array(input.frames.prefix(count))
        // Truncation must be visible: a chart showing 10 of 40 series looks
        // exactly like a chart of 10 series.
        if dropped > 0, !out.frames.isEmpty {
            out.frames[0].meta.notices.append("limit: \(dropped) more series not shown")
        }
        return out
    }
}

// MARK: - Pipeline

enum TransformationPipeline {
    /// Apply steps in order. An empty pipeline returns the input untouched.
    static func apply(_ steps: [any Transformation], to input: FrameSet) -> FrameSet {
        steps.reduce(input) { $1.apply($0) }
    }
}

// MARK: - Persisted pipeline
//
// The six transformations above have existed, with tests, since the frame
// contract landed — and nothing a user built could survive closing the editor,
// because `PanelConfig` had nowhere to put them. Only the hardcoded preset path
// ran. What follows is the storage shape: a list of steps, each naming one of
// the transformations by its `id`, carrying its options, and switchable off
// without being deleted (FR-028).
//
// Decoding is deliberately forgiving. A step this build cannot construct — a
// type from a newer build, or options it cannot read — becomes `.unknown`,
// which applies nothing and re-encodes exactly what was on disk. Failing the
// decode instead would fail the panel, and through it the dashboard, which is
// the one thing here that cannot be rebuilt (헌장 원칙 III, 계약 C1).

/// One stored step of a panel's transformation pipeline.
struct TransformationStep: Codable, Equatable, Identifiable, Sendable {
    /// List identity for SwiftUI only, never persisted — the same reason
    /// `ThresholdStep` carries one. Iterating by offset renumbers every row on
    /// insert and reorder, and animates identity churn through the whole list.
    var id: UUID = UUID()

    var kind: Kind

    /// Off, but kept. A reader comparing "with and without this step" should
    /// not have to rebuild it, and FR-028 asks for exactly this.
    var disabled: Bool = false

    init(id: UUID = UUID(), kind: Kind, disabled: Bool = false) {
        self.id = id
        self.kind = kind
        self.disabled = disabled
    }

    /// Which transformation, and with what options.
    enum Kind: Equatable, Sendable {
        case reduce(ReduceTransformation)
        case calculateField(CalculateFieldTransformation)
        case organize(OrganizeTransformation)
        case filterByValue(FilterByValueTransformation)
        case sortBy(SortByTransformation)
        case limit(LimitTransformation)
        /// A step this build has no case for, kept verbatim. It applies
        /// nothing and is written back as it arrived.
        case unknown(id: String, options: [String: JSONValue])

        /// The identifier written to disk.
        var typeID: String {
            switch self {
            case .reduce:         return ReduceTransformation.id
            case .calculateField: return CalculateFieldTransformation.id
            case .organize:       return OrganizeTransformation.id
            case .filterByValue:  return FilterByValueTransformation.id
            case .sortBy:         return SortByTransformation.id
            case .limit:          return LimitTransformation.id
            case let .unknown(id, _): return id
            }
        }
    }

    /// The transformation to run, or nil when there is nothing to run: the step
    /// is switched off, or this build does not know the type.
    var transformation: (any Transformation)? {
        guard !disabled else { return nil }
        switch kind {
        case let .reduce(t):         return t
        case let .calculateField(t): return t
        case let .organize(t):       return t
        case let .filterByValue(t):  return t
        case let .sortBy(t):         return t
        case let .limit(t):          return t
        case .unknown:               return nil
        }
    }

    /// True for a step this build cannot run. The editor says so rather than
    /// drawing an empty row the reader cannot explain.
    var isUnknown: Bool {
        if case .unknown = kind { return true }
        return false
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, disabled, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .id)
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        id = UUID()

        /// Options that fail to decode do not fail the panel: the step falls
        /// through to `.unknown`, which keeps them intact on the way out.
        func raw() -> [String: JSONValue] {
            (try? c.decodeIfPresent([String: JSONValue].self, forKey: .options)) ?? [:]
        }

        switch type {
        case ReduceTransformation.id:
            kind = .reduce((try? c.decode(ReduceTransformation.self, forKey: .options))
                           ?? ReduceTransformation())
        case OrganizeTransformation.id:
            kind = .organize((try? c.decode(OrganizeTransformation.self, forKey: .options))
                             ?? OrganizeTransformation())
        case CalculateFieldTransformation.id:
            if let t = try? c.decode(CalculateFieldTransformation.self, forKey: .options) {
                kind = .calculateField(t)
            } else {
                kind = .unknown(id: type, options: raw())
            }
        case FilterByValueTransformation.id:
            if let t = try? c.decode(FilterByValueTransformation.self, forKey: .options) {
                kind = .filterByValue(t)
            } else {
                kind = .unknown(id: type, options: raw())
            }
        case SortByTransformation.id:
            if let t = try? c.decode(SortByTransformation.self, forKey: .options) {
                kind = .sortBy(t)
            } else {
                kind = .unknown(id: type, options: raw())
            }
        case LimitTransformation.id:
            if let t = try? c.decode(LimitTransformation.self, forKey: .options) {
                kind = .limit(t)
            } else {
                kind = .unknown(id: type, options: raw())
            }
        default:
            kind = .unknown(id: type, options: raw())
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.typeID, forKey: .id)
        // Written only when true, so a pipeline built before this flag existed
        // re-encodes byte for byte.
        if disabled { try c.encode(true, forKey: .disabled) }
        switch kind {
        case let .reduce(t):         try c.encode(t, forKey: .options)
        case let .calculateField(t): try c.encode(t, forKey: .options)
        case let .organize(t):       try c.encode(t, forKey: .options)
        case let .filterByValue(t):  try c.encode(t, forKey: .options)
        case let .sortBy(t):         try c.encode(t, forKey: .options)
        case let .limit(t):          try c.encode(t, forKey: .options)
        case let .unknown(_, options):
            if !options.isEmpty { try c.encode(options, forKey: .options) }
        }
    }
}

// MARK: - Lenient option decoding
//
// Every option is optional on the way in, with the same default the editor
// starts from. A step written by a build that did not have one of these
// properties yet decodes as the property's default rather than throwing.

extension ReduceTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reducer = try c.decodeIfPresent(Reducer.self, forKey: .reducer) ?? .lastNotNull
    }
}

extension CalculateFieldTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decode(String.self, forKey: .left)
        right = try c.decode(String.self, forKey: .right)
        operation = try c.decodeIfPresent(Operation.self, forKey: .operation) ?? .add
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        replaceFields = try c.decodeIfPresent(Bool.self, forKey: .replaceFields) ?? false
    }
}

extension OrganizeTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excluded = try c.decodeIfPresent(Set<String>.self, forKey: .excluded) ?? []
        renamed = try c.decodeIfPresent([String: String].self, forKey: .renamed) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
    }
}

extension FilterByValueTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        comparison = try c.decodeIfPresent(Comparison.self, forKey: .comparison) ?? .greater
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
    }
}

extension SortByTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(String.self, forKey: .field)
        reducer = try c.decodeIfPresent(ReduceTransformation.Reducer.self, forKey: .reducer) ?? .sum
        descending = try c.decodeIfPresent(Bool.self, forKey: .descending) ?? true
    }
}

extension LimitTransformation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
    }
}

// MARK: - Running a stored pipeline

extension TransformationPipeline {
    /// Apply stored steps in order, skipping the ones switched off and the ones
    /// this build cannot run.
    static func apply(steps: [TransformationStep], to input: FrameSet) -> FrameSet {
        apply(steps.compactMap(\.transformation), to: input)
    }
}
