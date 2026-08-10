import Testing
import Foundation
@testable import TokiMonitor

/// Transformations are the half of the freedom that does not come from the
/// query language. The milestone they exist for: a new number can be produced
/// WITHOUT adding a `PanelMetric` case and a matching renderer branch.
@Suite("Transformations")
struct TransformationTests {

    private func frame(_ name: String,
                       _ columns: [String: [Double?]],
                       labels: [String: String] = [:],
                       times: Int? = nil) -> Frame {
        let n = times ?? columns.values.first?.count ?? 0
        var fields: [Field] = [
            Field(name: "time", labels: labels,
                  values: .time((0..<n).map { Date(timeIntervalSince1970: Double($0) * 3600) }))
        ]
        for key in columns.keys.sorted() {
            fields.append(Field(name: key, labels: labels, values: .number(columns[key]!)))
        }
        return Frame(refId: "A", name: name, fields: fields)
    }

    // MARK: - Reduce

    @Test("reduce collapses a series to one value per numeric field")
    func reduceCollapses() throws {
        let set = FrameSet(frames: [frame("s", ["v": [1, 2, 3]])])
        let out = ReduceTransformation(reducer: .sum).apply(set)
        let f = try #require(out.frames.first)
        #expect(f.rowCount == 1)
        #expect(f.field(named: "v")?.values.numbers == [6])
        // The time column is what made it a series; a reduced frame is a row.
        #expect(f.timeField == nil)
    }

    /// A window with no data is not a window that measured zero, and a stat
    /// card showing "0" for "nothing here" is undetectable to the reader.
    @Test("an all-null series reduces to nil, never to zero")
    func nullsDoNotBecomeZero() {
        let empty: [Double?] = [nil, nil]
        #expect(ReduceTransformation.reduce(empty, using: .sum) == nil)
        #expect(ReduceTransformation.reduce(empty, using: .mean) == nil)
        #expect(ReduceTransformation.reduce(empty, using: .max) == nil)
        // count is the exception: "how many present values" of none is 0.
        #expect(ReduceTransformation.reduce(empty, using: .count) == 0)
    }

    @Test("lastNotNull skips trailing gaps that `last` would report")
    func lastNotNullSkipsGaps() {
        let v: [Double?] = [5, 7, nil]
        #expect(ReduceTransformation.reduce(v, using: .last) == nil)
        #expect(ReduceTransformation.reduce(v, using: .lastNotNull) == 7)
    }

    // MARK: - Calculate field — the PanelMetric replacement

    /// `cacheHitRate` exists as an enum case only because the query language
    /// has no binary operator. Expressed as a transformation it needs neither
    /// an enum entry nor a renderer branch.
    @Test("a ratio is expressible without a PanelMetric case")
    func ratioWithoutEnum() throws {
        let set = FrameSet(frames: [frame("s", [
            "cache_read_input_tokens": [75, 40],
            "input_tokens": [25, 60],
        ])])
        let denominator = CalculateFieldTransformation(
            left: "cache_read_input_tokens", right: "input_tokens",
            operation: .add, alias: "reads_plus_input"
        )
        let ratio = CalculateFieldTransformation(
            left: "cache_read_input_tokens", right: "reads_plus_input",
            operation: .divide, alias: "cache_hit_rate"
        )
        let out = TransformationPipeline.apply([denominator, ratio], to: set)
        let f = try #require(out.frames.first)
        #expect(f.field(named: "cache_hit_rate")?.values.numbers == [0.75, 0.4])
    }

    /// An infinite point rescales the axis and hides every real value.
    @Test("division by zero yields nil rather than infinity")
    func divideByZeroIsNil() throws {
        let set = FrameSet(frames: [frame("s", ["a": [1, 2], "b": [0, 2]])])
        let out = CalculateFieldTransformation(left: "a", right: "b",
                                               operation: .divide, alias: "r").apply(set)
        let values = try #require(out.frames.first?.field(named: "r")?.values.numbers)
        #expect(values[0] == nil)
        #expect(values[1] == 1)
    }

    @Test("a missing input is reported, not silently skipped")
    func missingInputIsReported() {
        let set = FrameSet(frames: [frame("s", ["a": [1]])])
        let out = CalculateFieldTransformation(left: "a", right: "nope",
                                               operation: .add).apply(set)
        #expect(out.notices.contains { $0.contains("nope") })
    }

    // MARK: - Organize

    @Test("organize renames, hides and reorders")
    func organizeWorks() throws {
        let set = FrameSet(frames: [frame("s", ["a": [1], "b": [2], "c": [3]])])
        let out = OrganizeTransformation(
            excluded: ["b"], renamed: ["a": "alpha"], order: ["c", "alpha"]
        ).apply(set)
        let f = try #require(out.frames.first)
        #expect(f.field(named: "b") == nil)
        #expect(f.field(named: "alpha")?.values.numbers == [1])
        let names = f.fields.map(\.name)
        #expect(names.firstIndex(of: "c")! < names.firstIndex(of: "alpha")!)
    }

    // MARK: - Filter

    @Test("filtering rows keeps every column the same length")
    func filterStaysRectangular() throws {
        let set = FrameSet(frames: [frame("s", ["v": [1, 50, 3]])])
        let out = FilterByValueTransformation(field: "v", comparison: .greater, value: 10)
            .apply(set)
        let f = try #require(out.frames.first)
        #expect(f.field(named: "v")?.values.numbers == [50])
        #expect(f.rowCount == 1)
        #expect(f.isRectangular, "the time column must be filtered alongside the values")
    }

    @Test("a null row cannot satisfy a numeric comparison")
    func nullRowsAreDropped() throws {
        let set = FrameSet(frames: [frame("s", ["v": [nil, 5]])])
        let out = FilterByValueTransformation(field: "v", comparison: .greater, value: 0)
            .apply(set)
        #expect(out.frames.first?.field(named: "v")?.values.numbers == [5])
    }

    // MARK: - Sort + limit = topk

    @Test("sort by a reduced field, descending")
    func sortsByReducedValue() {
        let set = FrameSet(frames: [
            frame("small", ["v": [1, 1]]),
            frame("big", ["v": [50, 50]]),
            frame("mid", ["v": [10, 10]]),
        ])
        let out = SortByTransformation(field: "v", reducer: .sum).apply(set)
        #expect(out.frames.map(\.name) == ["big", "mid", "small"])
    }

    /// Treating "no value" as zero would sort an absent series above a real
    /// negative one; it belongs last regardless of direction.
    @Test("series with no value sort last in both directions")
    func absentSortsLast() {
        let set = FrameSet(frames: [
            frame("none", ["v": [nil, nil]]),
            frame("has", ["v": [3, 4]]),
        ])
        #expect(SortByTransformation(field: "v", descending: true).apply(set)
                    .frames.map(\.name) == ["has", "none"])
        #expect(SortByTransformation(field: "v", descending: false).apply(set)
                    .frames.map(\.name) == ["has", "none"])
    }

    /// A chart of 10 series looks identical whether it is all of them or the
    /// first 10 of 40.
    @Test("limit reports what it dropped")
    func limitIsHonest() {
        let set = FrameSet(frames: (0..<5).map { frame("s\($0)", ["v": [Double($0)]]) })
        let out = LimitTransformation(count: 2).apply(set)
        #expect(out.frames.count == 2)
        #expect(out.notices.contains { $0.contains("3 more") })
    }

    @Test("topk is sort plus limit")
    func topKComposes() {
        let set = FrameSet(frames: [
            frame("a", ["v": [1]]), frame("b", ["v": [9]]), frame("c", ["v": [5]]),
        ])
        let out = TransformationPipeline.apply(
            [SortByTransformation(field: "v"), LimitTransformation(count: 2)], to: set
        )
        #expect(out.frames.map(\.name) == ["b", "c"])
    }

    // MARK: - Pipeline

    @Test("an empty pipeline is the identity")
    func emptyPipelineIsIdentity() {
        let set = FrameSet(frames: [frame("s", ["v": [1, 2]])])
        #expect(TransformationPipeline.apply([], to: set) == set)
    }

    @Test("steps apply in order, and order matters")
    func orderMatters() throws {
        let set = FrameSet(frames: [frame("s", ["v": [1, 100]])])
        // filter then reduce: the big value survives the filter and is summed
        let filterFirst = TransformationPipeline.apply(
            [FilterByValueTransformation(field: "v", comparison: .greater, value: 50),
             ReduceTransformation(reducer: .sum)], to: set)
        #expect(filterFirst.frames.first?.field(named: "v")?.values.numbers == [100])

        // reduce then filter: the sum (101) passes, so nothing is removed
        let reduceFirst = TransformationPipeline.apply(
            [ReduceTransformation(reducer: .sum),
             FilterByValueTransformation(field: "v", comparison: .greater, value: 50)], to: set)
        #expect(reduceFirst.frames.first?.field(named: "v")?.values.numbers == [101])
    }
}
