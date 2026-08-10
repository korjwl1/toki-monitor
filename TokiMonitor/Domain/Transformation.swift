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
struct ReduceTransformation: Transformation {
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
struct CalculateFieldTransformation: Transformation {
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
struct OrganizeTransformation: Transformation {
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
struct FilterByValueTransformation: Transformation {
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
struct SortByTransformation: Transformation {
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
struct LimitTransformation: Transformation {
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
