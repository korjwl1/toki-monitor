import SwiftUI

/// Full-screen panel editor with tabs: Query, Visualization, Options.
/// Inspired by Grafana's panel edit view.
struct PanelEditorView: View {
    @State private var panel: PanelConfig
    @Bindable var viewModel: DashboardViewModel
    let onSave: (PanelConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: EditorTab = .query

    /// This panel's own result, fetched for the preview. Not the dashboard's:
    /// the panel being edited is unsaved, so its query has no entry in
    /// `viewModel.panelData` and reading one would show the pre-edit answer.
    @State private var previewState: PanelDataState = .idle
    /// A re-fetch on every keystroke would fork a `toki` subprocess per
    /// character, so the preview re-runs only when what would be SENT changes
    /// — see `previewKey`.
    @State private var previewTask: Task<Void, Never>?

    enum EditorTab: String, CaseIterable {
        case query
        case visualization
        case options
        case links

        var label: String {
            switch self {
            case .query: L.tr("쿼리", "Query")
            case .visualization: L.tr("시각화", "Visualization")
            case .options: L.tr("옵션", "Options")
            case .links: L.dash.dataLinks
            }
        }

        var icon: String {
            switch self {
            case .query: "terminal"
            case .visualization: "chart.xyaxis.line"
            case .options: "gearshape"
            case .links: "link"
            }
        }
    }

    init(panel: PanelConfig, viewModel: DashboardViewModel, onSave: @escaping (PanelConfig) -> Void) {
        _panel = State(initialValue: panel)
        self.viewModel = viewModel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            editorHeader

            Divider()

            HSplitView {
                // Left: Panel preview
                panelPreview
                    .frame(minWidth: 300)

                // Right: Editor tabs
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    tabContent
                }
                .frame(minWidth: 320, idealWidth: 380)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    // MARK: - Header

    private var editorHeader: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(L.tr("뒤로", "Back"))
                }
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            TextField(L.tr("패널 제목", "Panel title"), text: $panel.title)
                .textFieldStyle(.plain)
                .font(.headline)

            Spacer()

            Button(L.dash.cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(L.tr("적용", "Apply")) {
                onSave(panel)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(EditorTab.allCases, id: \.rawValue) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.caption)
                        Text(tab.label)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        selectedTab == tab
                            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                            : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selectedTab {
                case .query:
                    PanelEditorQueryTab(
                        panel: $panel,
                        backend: viewModel.suggestionDialect,
                        time: viewModel.dashboardConfig.time,
                        variables: viewModel.dashboardConfig.templating.list
                    )
                case .visualization: PanelEditorVisualizationTab(panel: $panel)
                case .options:       PanelEditorOptionsTab(panel: $panel)
                case .links:         PanelEditorDataLinksTab(panel: $panel)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Panel Preview

    private var panelPreview: some View {
        VStack {
            GroupBox {
                previewContent
            } label: {
                HStack(spacing: DS.sm) {
                    Text(panel.title)
                        .font(.headline)
                    if previewState.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Text(DatasourceKindDisplay.name(for: viewModel.activeDatasource.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(.background)
        .task(id: previewKey) { await refreshPreview() }
    }

    /// The interpolated queries this panel would send. Preview re-runs when it
    /// changes — and only then.
    private var previewKey: String {
        PanelFetchCoordinator
            .plan(for: panel,
                  time: viewModel.dashboardConfig.time,
                  variables: viewModel.dashboardConfig.templating.list)
            .map { "\($0.refId)|\($0.hidden)|\($0.query)" }
            .joined(separator: "\n")
    }

    private func refreshPreview() async {
        previewTask?.cancel()
        previewState = .loading(previous: previewState.timeSeriesData,
                                previousFrames: previewState.frames)
        let target = panel
        let task = Task { [weak viewModel] in
            guard let viewModel else { return }
            let state = await viewModel.fetchPreview(for: target)
            if Task.isCancelled { return }
            previewState = state
        }
        previewTask = task
        await task.value
    }

    /// The real panel, drawn from this panel's own result, through the same
    /// view the dashboard uses. It used to be the literal word "미리보기" for
    /// every type but stat — and stat read the global `timeSeriesData`, so the
    /// one screen whose job is showing what a query change does showed either
    /// nothing or another panel's numbers.
    @ViewBuilder
    private var previewContent: some View {
        let state = PanelState.resolve(
            previewState,
            hasContent: CustomDashboardView.hasContent(previewState)
        )
        VStack(spacing: 0) {
            switch state {
            case .loaded, .loading(hasPrevious: true):
                PanelContentView(
                    panel: panel,
                    data: previewState.timeSeriesData,
                    frames: previewState.frames,
                    viewModel: viewModel,
                    dateFormat: PanelDateFormat.forBucket(
                        seconds: viewModel.dashboardConfig.time.bucketSeconds
                    )
                )
                .opacity(state.isStale ? 0.45 : 1)
            case .idle, .loading(hasPrevious: false), .empty, .failed:
                PanelStatusView(state: state, onRetry: { Task { await refreshPreview() } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
