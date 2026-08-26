import Foundation

// MARK: - What a panel's result contains, as numbers
//
// The inspector could show what ran, what came back and how the app read it —
// but "what came back" was a list of series names and row counts. The questions
// a reader actually opens the inspector with ("is this spike real or one bad
// sample?", "why is the line flat — is it zero or is it missing?") need the
// distribution, and every one of them is a reduction over the same columns the
// chart is drawing.
//
// Domain, and pure. The inspector renders these; nothing here knows it exists.

/// One numeric column of one frame, reduced.
struct SeriesStat: Equatable, Identifiable, Sendable {
    /// Which query produced it.
    let refId: String
    /// The series name the chart draws it under.
    let series: String
    /// The column within that series.
    let field: String

    /// Samples present. Absent samples are counted separately: a mean over 4
    /// of 96 buckets and a mean over all 96 are not the same claim, and a
    /// single "count" cannot tell them apart.
    let count: Int
    /// Samples the query returned as absent.
    let gaps: Int

    let min: Double?
    let max: Double?
    let mean: Double?
    let sum: Double
    /// The most recent present sample — what a stat card would show.
    let last: Double?
    /// The span the samples cover, when the frame has a time column.
    let firstTime: Date?
    let lastTime: Date?

    var id: String { "\(refId)|\(series)|\(field)" }

    /// True when the column has no present samples at all. Worth naming: it is
    /// the difference between "the line is at zero" and "there is no line".
    var isAllGaps: Bool { count == 0 && gaps > 0 }
}

enum SeriesStatistics {

    /// Reduce every numeric column of every frame.
    ///
    /// Frames in the order they arrived and columns in declaration order — the
    /// same order the data tab lists them, so a reader comparing the two tabs
    /// is looking at the same rows in the same places.
    static func compute(_ set: FrameSet) -> [SeriesStat] {
        set.frames.flatMap { frame in
            frame.numberFields.map { field in
                stat(of: field, in: frame)
            }
        }
    }

    static func stat(of field: Field, in frame: Frame) -> SeriesStat {
        let raw = field.values.numbers ?? []
        let present = raw.compactMap { $0 }
        let times = Self.times(of: frame)
        return SeriesStat(
            refId: frame.refId,
            series: frame.displayName,
            field: field.name,
            count: present.count,
            gaps: raw.count - present.count,
            min: present.min(),
            max: present.max(),
            // Mean over the samples that exist. Dividing by the bucket count
            // instead would report a series that answered four times out of
            // ninety-six as mostly zero, which is a different — and wrong —
            // statement about the data.
            mean: present.isEmpty ? nil : present.reduce(0, +) / Double(present.count),
            sum: present.reduce(0, +),
            last: lastPresent(raw),
            firstTime: times?.first,
            lastTime: times?.last
        )
    }

    /// The frame's time column, as dates.
    ///
    /// `FieldValues` has a `numbers` view and no `times` one, which is the
    /// right default — nothing else needs to read a time column generically —
    /// so the unwrap lives here rather than widening that type.
    static func times(of frame: Frame) -> [Date]? {
        guard case let .time(values)? = frame.timeField?.values else { return nil }
        return values
    }

    /// The most recent present sample, skipping trailing gaps.
    private static func lastPresent(_ values: [Double?]) -> Double? {
        for value in values.reversed() {
            if let value { return value }
        }
        return nil
    }
}

// MARK: - Taking the result away

/// The panel's result as a file.
///
/// Separate from `DashboardExchange`, which exports CONFIGURATION and is bound
/// by 계약 C3 to carry no usage numbers. This is the opposite export and the
/// reason C3 can be strict: someone who wants the numbers has a way to ask for
/// exactly them, deliberately, one panel at a time.
enum FrameExport {

    /// Long format: one row per sample.
    ///
    /// Wide format — a column per field — is what a spreadsheet wants, and it
    /// cannot represent this input: two frames of one result may have different
    /// columns, different lengths and different time bases, and flattening them
    /// side by side either invents alignment or drops data. One row per sample
    /// carries every frame shape without either.
    static func csv(_ set: FrameSet) -> String {
        var lines = ["refId,series,labels,time,field,value"]
        for frame in set.frames {
            let labels = frame.commonLabels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ";")
            let times = SeriesStatistics.times(of: frame)
            for field in frame.numberFields {
                let numbers = field.values.numbers ?? []
                for (index, value) in numbers.enumerated() {
                    let time = index < (times?.count ?? 0)
                        ? isoString(times![index]) : ""
                    lines.append([
                        escape(frame.refId), escape(frame.displayName), escape(labels),
                        time, escape(field.name),
                        // An absent sample is an empty cell, never a zero. The
                        // whole point of carrying gaps this far is that they do
                        // not become numbers on the way out.
                        value.map { String($0) } ?? "",
                    ].joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A filename that says which panel and which moment, so two exports of the
    /// same panel do not overwrite each other.
    static func filename(panelTitle: String, at date: Date = Date()) -> String {
        let when = stamp(date)
        let safe = panelTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe.isEmpty ? "panel" : safe)-\(when).csv"
    }

    /// RFC 4180: a field containing a comma, a quote or a newline is quoted,
    /// and its own quotes are doubled.
    static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Built per call rather than cached. `ISO8601DateFormatter` is not
    /// `Sendable`, and an export is one user action — the allocation is
    /// nothing beside the file write it precedes.
    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
