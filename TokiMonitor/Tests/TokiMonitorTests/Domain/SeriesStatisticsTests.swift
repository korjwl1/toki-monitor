import Testing
import Foundation
@testable import TokiMonitor

@Suite("Series statistics and result export")
@MainActor
struct SeriesStatisticsTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func frame(_ name: String, _ values: [Double?]) -> Frame {
        Frame(refId: "A", fields: [
            Field(name: "time", labels: ["model": name],
                  values: .time(values.indices.map { t0.addingTimeInterval(Double($0) * 3_600) })),
            Field(name: "total_tokens", labels: ["model": name], values: .number(values)),
        ])
    }

    @Test("a column is reduced to what a reader asks the inspector for")
    func basicReduction() {
        let stats = SeriesStatistics.compute(FrameSet(frames: [frame("opus", [10, 30, 20])]))
        #expect(stats.count == 1)
        let stat = stats[0]
        #expect(stat.count == 3)
        #expect(stat.gaps == 0)
        #expect(stat.min == 10)
        #expect(stat.max == 30)
        #expect(stat.mean == 20)
        #expect(stat.sum == 60)
        #expect(stat.last == 20)
        #expect(stat.firstTime == t0)
    }

    @Test("gaps are counted, not averaged in as zero")
    func gapsAreNotZero() {
        let stat = SeriesStatistics.compute(FrameSet(frames: [frame("opus", [10, nil, 30])]))[0]
        #expect(stat.count == 2)
        #expect(stat.gaps == 1)
        #expect(stat.mean == 20,
                "an absent bucket averaged in as zero would give 13.3 and read as a dip")
        #expect(stat.sum == 40)
    }

    @Test("a trailing gap does not become the last value")
    func lastSkipsTrailingGaps() {
        let stat = SeriesStatistics.compute(FrameSet(frames: [frame("opus", [10, 30, nil])]))[0]
        #expect(stat.last == 30)
    }

    @Test("a column with nothing in it says so, rather than reading as zero")
    func allGapsIsNamed() {
        let stat = SeriesStatistics.compute(FrameSet(frames: [frame("opus", [nil, nil])]))[0]
        #expect(stat.isAllGaps)
        #expect(stat.mean == nil)
        #expect(stat.min == nil)
        #expect(stat.count == 0)
        #expect(stat.gaps == 2)
    }

    @Test("every numeric column of every series gets a row")
    func everyColumnIsCovered() {
        let stats = SeriesStatistics.compute(PanelSnapshotFixtures.frames)
        // Two series × two numeric columns (tokens, cost). The time column is
        // not a measure and does not get one.
        #expect(stats.count == 4)
        #expect(Set(stats.map(\.field)) == ["total_tokens", "cost_usd"])
        #expect(Set(stats.map(\.id)).count == stats.count)
    }

    @Test("an empty result produces no rows rather than a row of zeroes")
    func emptyResult() {
        #expect(SeriesStatistics.compute(FrameSet()).isEmpty)
    }

    // MARK: - Export

    @Test("the CSV has one row per sample and a header")
    func csvShape() {
        let csv = FrameExport.csv(FrameSet(frames: [frame("opus", [10, 20])]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.first == "refId,series,labels,time,field,value")
        #expect(lines.count == 3)
        #expect(lines[1].hasSuffix(",total_tokens,10.0"))
    }

    @Test("an absent sample exports as an empty cell, never as zero")
    func csvKeepsGapsAbsent() {
        let csv = FrameExport.csv(FrameSet(frames: [frame("opus", [nil])]))
        let row = csv.split(separator: "\n")[1]
        #expect(row.hasSuffix(","),
                "a gap written as 0 is a false number in someone's spreadsheet: \(row)")
    }

    @Test("the export carries the labels that identify a series")
    func csvCarriesLabels() {
        let csv = FrameExport.csv(FrameSet(frames: [frame("opus", [10])]))
        #expect(csv.contains("model=opus"))
    }

    @Test("a comma or a quote in a series name does not break the file")
    func csvEscapes() {
        #expect(FrameExport.escape("a,b") == "\"a,b\"")
        #expect(FrameExport.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(FrameExport.escape("plain") == "plain")
    }

    @Test("the filename names the panel and the moment")
    func filenameIsSpecific() {
        let name = FrameExport.filename(panelTitle: "Tokens/day", at: t0)
        #expect(name.hasSuffix(".csv"))
        #expect(!name.contains("/"), "a slash would be a path component, not a name")
        #expect(name.contains("Tokens-day"))
        let other = FrameExport.filename(panelTitle: "", at: t0)
        #expect(other.hasPrefix("panel-"), "an untitled panel still gets a filename")
    }
}
