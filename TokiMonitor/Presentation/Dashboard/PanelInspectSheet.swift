import SwiftUI

/// Panel Inspect — "where did this number come from?"
///
/// A Grafana user reaches for this reflexively when a panel looks wrong, and
/// its absence is why a dashboard cannot be trusted: every number is an
/// assertion with no way to check it. It matters more here than in Grafana,
/// because the wire encodes grouping dimensions positionally inside a period
/// string, so what the user asked for and what came back can differ in ways
/// no chart reveals.
///
/// Three tabs, in the order a diagnosis actually proceeds: what ran, what came
/// back, and how the app understood it.
struct PanelInspectSheet: View {
    let panel: PanelConfig
    let state: PanelDataState
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .data

    enum Tab: String, CaseIterable, Identifiable {
        case data, query, json
        var id: String { rawValue }
        var title: String {
            switch self {
            case .data:  return L.tr("데이터", "Data")
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L.tr("닫기", "Close")) { dismiss() }
        }
        .padding(12)
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
                    .font(.callout).foregroundStyle(.secondary)
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
                        .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)

                if !frame.isRectangular {
                    Label(L.tr("필드 길이가 다릅니다 (생성 측 버그)",
                               "fields have unequal length (producer bug)"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

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
