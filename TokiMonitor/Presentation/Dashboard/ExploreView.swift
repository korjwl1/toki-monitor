import SwiftUI
import Charts

/// Explore mode: free-form PromQL query input with live results.
///
/// Three things this screen owes the reader, and none of them were here:
/// its own time range (so trying a query does not move the dashboard behind
/// it), the backend's refusal when there is one (rather than the same empty
/// screen as never having run anything), and a way to keep a query that
/// worked — otherwise trying and keeping are two unrelated activities and the
/// second one is done by retyping.
struct ExploreView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var showHistory = false
    @State private var showPromote = false
    @State private var promoteTitle = ""
    @State private var promoteType: PanelType = .timeSeries
    @FocusState private var queryFocused: Bool
    /// Cached suggestion list. Recomputed only on actual query text
    /// changes (via `.onChange`) instead of every body re-evaluation —
    /// SwiftUI re-runs `body` for unrelated state too (focus, loading,
    /// etc.), and the suggester tokenization + filter shouldn't ride
    /// along on those.
    @State private var cachedSuggestions: (token: String, items: [PromQLSuggestion]) = ("", [])

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderView(title: L.dash.explore, icon: "magnifyingglass.circle")

            queryBar
            suggestionStrip
            preflightNotice

            Divider()

            results
        }
        .sheet(isPresented: $showPromote) { promoteSheet }
    }

    // MARK: - Query bar

    private var queryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("PromQL", text: $viewModel.exploreQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .focused($queryFocused)
                .onSubmit {
                    viewModel.runExploreQuery()
                }
                .onChange(of: viewModel.exploreQuery) { _, newValue in
                    cachedSuggestions = PromQLSuggester.suggestions(for: newValue, dialect: viewModel.suggestionDialect)
                }
                .onAppear {
                    cachedSuggestions = PromQLSuggester.suggestions(for: viewModel.exploreQuery, dialect: viewModel.suggestionDialect)
                }

            // Explore's own range. It is deliberately not bound to
            // `viewModel.timeConfig`: changing that re-fetches every panel and
            // rewrites the saved dashboard, so widening a window to test a
            // query would edit the dashboard as a side effect.
            Picker("", selection: Binding(
                get: { viewModel.exploreTime.from },
                set: { viewModel.exploreTime = TimeConfig(from: $0, to: "now") }
            )) {
                ForEach(TimeRangePreset.presets, id: \.from) { preset in
                    Text(preset.label).tag(preset.from)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .help(L.tr("탐색 화면만의 시간 범위입니다. 대시보드는 바뀌지 않습니다.",
                       "Explore's own time range. The dashboard keeps its own."))

            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHistory) {
                queryHistoryPopover
            }

            Button(L.dash.runQuery) {
                viewModel.runExploreQuery()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.exploreQuery.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// What the selected backend is expected to make of the query. Advisory:
    /// the query is still sent, and the backend's own answer wins.
    @ViewBuilder
    private var preflightNotice: some View {
        if let validation = viewModel.exploreValidation,
           !validation.isValid, let reason = validation.reason {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .font(.caption2)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if viewModel.isExploreLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = viewModel.exploreError {
            errorView(message)
        } else if let frames = viewModel.exploreFrames {
            let series = FrameReader.allSeries(frames)
            if series.isEmpty {
                ContentUnavailableView(
                    L.tr("이 범위에 결과가 없습니다", "No results in this range"),
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text(L.tr(
                        "질의는 성공했지만 선택한 시간 범위에 해당하는 행이 없습니다.",
                        "The query succeeded but matched no rows in the selected time range."))
                )
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    resultToolbar
                    HSplitView {
                        exploreChart(series: series)
                            .frame(minHeight: 200)
                        exploreTable(series: series)
                            .frame(minHeight: 200)
                    }
                    .padding(16)
                }
            }
        } else {
            ContentUnavailableView(
                L.tr("쿼리를 입력하세요", "Enter a query"),
                systemImage: "terminal",
                description: Text(L.tr("PromQL 쿼리를 입력하고 실행하면 결과가 표시됩니다", "Enter a PromQL query and run it to see results"))
            )
            .frame(maxHeight: .infinity)
        }
    }

    /// The backend's own words. An error used to clear the result and leave the
    /// "enter a query" screen, which says the opposite of what happened: the
    /// query WAS run, and it was refused.
    private func errorView(_ message: String) -> some View {
        VStack(spacing: DS.sm) {
            Image(systemName: viewModel.exploreErrorIsRefusal
                  ? "exclamationmark.triangle.fill" : "wifi.exclamationmark")
                .font(.title)
                .foregroundStyle(.orange)
            Text(viewModel.exploreErrorIsRefusal
                 ? L.tr("백엔드가 이 질의를 실행하지 못했습니다",
                        "The backend could not execute this query")
                 : L.tr("질의를 실행하지 못했습니다", "The query could not be run"))
                .font(.headline)
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
            if let query = viewModel.exploreExecutedQuery {
                Text(query)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            // A refusal answers the same way every time; only a transport
            // failure is worth repeating unchanged.
            if !viewModel.exploreErrorIsRefusal {
                Button(L.tr("다시 시도", "Try again")) { viewModel.runExploreQuery() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var resultToolbar: some View {
        HStack(spacing: 8) {
            if let query = viewModel.exploreExecutedQuery {
                Text(query)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                promoteTitle = viewModel.exploreQuery
                showPromote = true
            } label: {
                Label(L.tr("패널로 추가", "Add as panel"), systemImage: "plus.rectangle.on.rectangle")
                    .font(.caption)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Promote to panel

    private var promoteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.tr("패널로 추가", "Add as panel"))
                .font(.headline)
            Text(L.tr("이 질의를 현재 대시보드의 새 패널로 만듭니다. 질의는 입력한 그대로 저장되므로 패널은 대시보드의 시간 범위를 따릅니다.",
                      "Creates a panel on the current dashboard from this query. The query is stored as written, so the panel follows the dashboard's time range."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L.tr("패널 제목", "Panel title"), text: $promoteTitle)
                .textFieldStyle(.roundedBorder)

            Picker(L.tr("패널 종류", "Panel type"), selection: $promoteType) {
                ForEach(PanelType.creatableTypes, id: \.rawValue) { type in
                    Text(type.displayName).tag(type)
                }
            }

            Text(viewModel.exploreQuery)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button(L.dash.cancel) { showPromote = false }
                    .keyboardShortcut(.cancelAction)
                Button(L.tr("추가", "Add")) {
                    viewModel.promoteExploreToPanel(title: promoteTitle, panelType: promoteType)
                    showPromote = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Autocomplete Suggestions

    @ViewBuilder
    private var suggestionStrip: some View {
        let result = cachedSuggestions
        if queryFocused, !result.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(result.items.prefix(20)) { suggestion in
                        Button {
                            viewModel.exploreQuery = PromQLSuggester.apply(
                                suggestion, to: viewModel.exploreQuery
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: suggestion.kind.systemImage)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(suggestion.text)
                                    .font(.system(.caption, design: .monospaced))
                                if let hint = suggestion.hint {
                                    Text(hint)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Query History

    private var queryHistoryPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.dash.queryHistory)
                    .font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.exploreQueryHistory.isEmpty {
                Text(L.tr("기록 없음", "No history"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                List(viewModel.exploreQueryHistory) { entry in
                    Button {
                        viewModel.exploreQuery = entry.query
                        showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.query)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320, height: 280)
    }

    // MARK: - Chart

    /// One line per series the frames carry — including series a panel metric
    /// has no name for. A gap stays a gap: an absent bucket is not zero.
    @ViewBuilder
    private func exploreChart(series: [(name: String, points: [(date: Date, value: Double?)])]) -> some View {
        Chart {
            ForEach(series, id: \.name) { entry in
                ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                    if let value = point.value {
                        LineMark(
                            x: .value(L.dash.axisTime, point.date),
                            y: .value(L.dash.axisTokens, value)
                        )
                        .foregroundStyle(by: .value(L.dash.axisModel, entry.name))
                    }
                }
            }
        }
    }

    // MARK: - Table

    @ViewBuilder
    private func exploreTable(series: [(name: String, points: [(date: Date, value: Double?)])]) -> some View {
        let rows = series.map { entry in
            ExploreRow(
                name: entry.name,
                total: entry.points.compactMap(\.value).reduce(0, +),
                samples: entry.points.compactMap(\.value).count
            )
        }
        Table(rows) {
            TableColumn(L.tr("계열", "Series"), value: \.name)
            TableColumn(L.tr("합계", "Total")) { row in
                Text(Self.formatValue(row.total))
            }
            TableColumn(L.tr("표본", "Samples")) { row in
                Text("\(row.samples)")
            }
        }
    }

    /// Explore does not know whether a column counts tokens or dollars, so it
    /// keeps the decimals a small number carries rather than rounding a cost of
    /// $3.42 to "3".
    private static func formatValue(_ value: Double) -> String {
        guard value >= 1000 else { return String(format: "%.2f", value) }
        return TokenFormatter.formatTokens(UInt64(value.rounded()))
    }

    /// One row of the result table. Explore has no metric to tell it what the
    /// numbers mean, so it reports what it can defend: the series identity, the
    /// sum of the present samples, and how many there were.
    private struct ExploreRow: Identifiable {
        let name: String
        let total: Double
        let samples: Int
        var id: String { name }
    }
}
