import SwiftUI

/// Full-screen panel editor with tabs: Query, Visualization, Options.
/// Inspired by Grafana's panel edit view.
struct PanelEditorView: View {
    @State private var panel: PanelConfig
    @Bindable var viewModel: DashboardViewModel
    let onSave: (PanelConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: EditorTab = .query

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
                case .query:         PanelEditorQueryTab(panel: $panel)
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
                Text(panel.title)
                    .font(.headline)
            }
            .padding(16)
        }
        .background(.background)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch panel.panelType {
        case .stat:
            let stat = PanelDataExtractor.statValue(
                for: panel.effectiveMetric,
                data: viewModel.timeSeriesData
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(stat.value)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                if let subtitle = stat.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .timeSeries, .barChart, .pieChart, .gauge, .stateTimeline, .rowPanel:
            Text(L.tr("미리보기", "Preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .table:
            Text(L.tr("미리보기", "Preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
