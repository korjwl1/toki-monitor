import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Panel Inspect — "where did this number come from?"
///
/// A Grafana user reaches for this reflexively when a panel looks wrong, and
/// its absence is why a dashboard cannot be trusted: every number is an
/// assertion with no way to check it. It matters more here than in Grafana,
/// because the wire encodes grouping dimensions positionally inside a period
/// string, so what the user asked for and what came back can differ in ways
/// no chart reveals.
///
/// Four tabs, in the order a diagnosis actually proceeds: what came back, how
/// it distributes, what ran, and how the app understood it.
///
/// The stats tab exists because the first three answer "what is here" and none
/// of them answers "is what is here plausible". A spike that is one bad sample
/// and a spike that is real look identical on a chart and differ obviously in
/// a min/max/mean; a flat line at the bottom is zeroes or gaps, and only the
/// gap count tells a reader which.
struct PanelInspectSheet: View {
    let panel: PanelConfig
    let state: PanelDataState
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .data
    /// A write that did not happen. Shown rather than swallowed: a save that
    /// silently produced no file is the same on screen as one that worked.
    @State private var exportFailure: String?

    enum Tab: String, CaseIterable, Identifiable {
        case data, stats, query, json
        var id: String { rawValue }
        var title: String {
            switch self {
            case .data:  return L.tr("데이터", "Data")
            case .stats: return L.tr("통계", "Stats")
            case .query: return L.tr("쿼리", "Query")
            case .json:  return "JSON"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()
            ScrollView {
                switch tab {
                case .data:  dataTab
                case .stats: statsTab
                case .query: queryTab
                case .json:  jsonTab
                }
            }
        }
        .frame(width: 720, height: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title).font(.headline)
                Text(L.tr("패널 검사", "Inspect panel"))
                    .font(.caption).foregroundStyle(DS.bodySecondary)
            }
            Spacer()
            // The result, as a file. `DashboardExchange` deliberately carries
            // no usage numbers (계약 C3); this is where someone who wants them
            // asks for them, one panel at a time and by name.
            Button {
                exportResult()
            } label: {
                Label(L.tr("CSV로 내보내기", "Export CSV"),
                      systemImage: "square.and.arrow.up")
            }
            .disabled(frames.isEmpty)
            .help(frames.isEmpty
                  ? L.tr("내보낼 결과가 없습니다", "There is no result to export")
                  : L.tr("이 패널의 결과를 CSV 파일로 저장합니다",
                         "Save this panel's result as a CSV file"))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(FrameExport.csv(state.frames ?? FrameSet()),
                                               forType: .string)
            } label: {
                Label(L.tr("CSV 복사", "Copy CSV"), systemImage: "doc.on.doc")
            }
            .disabled(frames.isEmpty)
            Button(L.tr("닫기", "Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    /// Ask where to put it, then write it. A save panel is the user's own
    /// choice of destination, which is what makes this export deliberate
    /// rather than something the app did with their numbers.
    private func exportResult() {
        let save = NSSavePanel()
        save.nameFieldStringValue = FrameExport.filename(panelTitle: panel.title)
        save.allowedContentTypes = [.commaSeparatedText]
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let url = save.url else { return }
        let csv = FrameExport.csv(state.frames ?? FrameSet())
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportFailure = error.localizedDescription
        }
    }

    // MARK: - Data

    private var frames: [Frame] { state.frames?.frames ?? [] }

    @ViewBuilder
    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case let .error(message) = state {
                labelled(L.tr("쿼리 실패", "Query failed"), message, tone: .red)
            }

            // Notices are the reason this pane exists: the adapter drops a
            // dimension it cannot split unambiguously, and a chart cannot show
            // that it did.
            let notices = state.frames?.notices ?? []
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.tr("경고", "Notices")).font(.subheadline.bold())
                    ForEach(notices, id: \.self) { n in
                        Label(n, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if frames.isEmpty {
                Text(state.frames == nil
                     ? L.tr("이 데이터 소스는 아직 프레임을 만들지 않습니다.",
                            "This data source does not produce frames yet.")
                     : L.tr("반환된 시리즈가 없습니다.", "The query returned no series."))
                    .font(.callout).foregroundStyle(DS.bodySecondary)
            } else {
                Text(L.tr("시리즈 \(frames.count)개", "\(frames.count) series"))
                    .font(.subheadline.bold())
                ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                    frameCard(frame)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func frameCard(_ frame: Frame) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(frame.displayName).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("refId \(frame.refId) · \(frame.rowCount) rows")
                        .font(.caption).foregroundStyle(DS.bodySecondary)
                }

                // The labels are the whole point of the frame contract: they
                // show that `by (model, project)` really produced two named
                // dimensions rather than one blended string.
                if !frame.commonLabels.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(frame.commonLabels.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            Text("\(k)=\(v)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Text(frame.fields.map { "\($0.name): \($0.type.rawValue)" }
                        .joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(DS.bodySecondary)

                if !frame.isRectangular {
                    Label(L.tr("필드 길이가 다릅니다 (생성 측 버그)",
                               "fields have unequal length (producer bug)"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsTab: some View {
        let stats = SeriesStatistics.compute(state.frames ?? FrameSet())
        VStack(alignment: .leading, spacing: 14) {
            if let exportFailure {
                labelled(L.tr("내보내기 실패", "Export failed"), exportFailure, tone: .red)
            }
            if stats.isEmpty {
                Text(L.tr("수치를 가진 열이 없습니다.",
                          "The result has no numeric columns."))
                    .font(.callout).foregroundStyle(DS.bodySecondary)
            } else {
                statsHeader
                ForEach(stats) { stat in
                    statsRow(stat)
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            ForEach(Self.statColumns, id: \.title) { column in
                Text(column.title)
                    .font(.system(size: DS.fontCaption, weight: .semibold))
                    .foregroundStyle(DS.bodySecondary)
                    .frame(width: column.width, alignment: column.alignment)
            }
        }
    }

    private func statsRow(_ stat: SeriesStat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stat.series)
                    .font(.system(size: DS.fontCaption))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(stat.refId) · \(stat.field)")
                    .font(.system(size: DS.fontTiny, design: .monospaced))
                    .foregroundStyle(DS.bodySecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: Self.statColumns[0].width, alignment: .leading)

            number(stat.count)
            // Gaps in their own column, beside the count. A mean over four of
            // ninety-six buckets is not the same claim as a mean over all of
            // them, and one number cannot say which this is.
            gapsCell(stat)
            number(stat.min)
            number(stat.max)
            number(stat.mean)
            number(stat.sum)
            number(stat.last)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(stat))
    }

    @ViewBuilder
    private func gapsCell(_ stat: SeriesStat) -> some View {
        HStack(spacing: 2) {
            if stat.isAllGaps {
                // Every sample absent. The chart for this series is a blank
                // stretch, and without this the reader reads it as zero.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(DS.threshold(.orange))
            }
            Text("\(stat.gaps)")
                .font(.system(size: DS.fontCaption, design: .monospaced))
        }
        .frame(width: Self.statColumns[2].width, alignment: .trailing)
        .help(stat.isAllGaps
              ? L.tr("이 열에는 값이 하나도 없습니다 — 0이 아니라 없음입니다.",
                     "This column has no values at all — absent, not zero.")
              : L.tr("값이 없는 표본 수", "Samples with no value"))
    }

    private func number(_ value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: DS.fontCaption, design: .monospaced))
            .frame(width: Self.statColumns[1].width, alignment: .trailing)
    }

    private func number(_ value: Double?) -> some View {
        Text(value.map { format($0) } ?? "-")
            .font(.system(size: DS.fontCaption, design: .monospaced))
            .lineLimit(1)
            .frame(width: Self.statColumns[3].width, alignment: .trailing)
    }

    /// The panel's own unit, so the stats read in the same notation the panel
    /// does. A mean of 24000 beside a chart labelled 24K is two readings of one
    /// number and makes the reader do the conversion.
    private func format(_ value: Double) -> String {
        if let display = StatPanelView.panelDisplayConfig(panel) {
            return FieldFormatter.format(value, config: display)
        }
        return StatPanelView.format(value, metric: panel.effectiveMetric)
    }

    private func spoken(_ stat: SeriesStat) -> String {
        let head = L.tr("\(stat.series), \(stat.field), 표본 \(stat.count)개, 빈 표본 \(stat.gaps)개",
                        "\(stat.series), \(stat.field), \(stat.count) samples, \(stat.gaps) gaps")
        guard let min = stat.min, let max = stat.max, let mean = stat.mean else {
            return L.tr("\(head), 값 없음", "\(head), no values")
        }
        return L.tr("\(head), 최소 \(format(min)), 최대 \(format(max)), 평균 \(format(mean)), 합계 \(format(stat.sum))",
                    "\(head), min \(format(min)), max \(format(max)), mean \(format(mean)), total \(format(stat.sum))")
    }

    private static let statColumns: [(title: String, width: CGFloat, alignment: Alignment)] = [
        (L.tr("시리즈", "Series"), 190, .leading),
        (L.tr("표본", "Count"), 56, .trailing),
        (L.tr("빈 값", "Gaps"), 60, .trailing),
        (L.tr("최소", "Min"), 80, .trailing),
        (L.tr("최대", "Max"), 80, .trailing),
        (L.tr("평균", "Mean"), 80, .trailing),
        (L.tr("합계", "Total"), 80, .trailing),
        (L.tr("마지막", "Last"), 80, .trailing),
    ]

    // MARK: - Query

    @ViewBuilder
    private var queryTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The query AFTER interpolation — the panel's stored text is not
            // what ran, and the difference is exactly where variable bugs hide.
            let executed = frames.compactMap(\.meta.executedQuery).first
            labelled(L.tr("실행된 쿼리", "Executed query"),
                     executed ?? panel.resolvedTokiQuery?.effectiveQuery
                        ?? panel.effectiveMetric.defaultQuery,
                     monospaced: true)

            if let ds = frames.compactMap(\.meta.datasource).first {
                labelled(L.tr("데이터 소스", "Datasource"), ds)
            }

            if panel.targets.count > 1 {
                labelled(
                    L.tr("쿼리 \(panel.targets.count)개 중 A만 실행됩니다",
                         "\(panel.targets.count) queries defined, only A is executed"),
                    panel.targets.dropFirst()
                        .map { "\($0.refId): \($0.query ?? $0.metric.rawValue)" }
                        .joined(separator: "\n"),
                    tone: .orange, monospaced: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - JSON

    private var jsonTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.tr("패널 정의", "Panel definition"))
                .font(.subheadline.bold())
            Text(panelJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private var panelJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(panel),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: - Shared

    private func labelled(_ title: String, _ body: String,
                          tone: Color = .primary, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(body)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(tone)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
