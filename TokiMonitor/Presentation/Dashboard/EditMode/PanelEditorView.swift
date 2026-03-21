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

        var label: String {
            switch self {
            case .query: L.tr("쿼리", "Query")
            case .visualization: L.tr("시각화", "Visualization")
            case .options: L.tr("옵션", "Options")
            }
        }

        var icon: String {
            switch self {
            case .query: "terminal"
            case .visualization: "chart.xyaxis.line"
            case .options: "gearshape"
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
                    queryTab
                case .visualization:
                    visualizationTab
                case .options:
                    optionsTab
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
                timeSeriesData: viewModel.timeSeriesData,
                viewModel: viewModel
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(stat.value)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                if let subtitle = stat.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .timeSeries, .barChart, .gauge:
            Text(L.tr("미리보기", "Preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .table:
            Text(L.tr("미리보기", "Preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Query Tab

    private var queryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Target list
            Text(L.tr("데이터 쿼리", "Data queries"))
                .font(.subheadline.bold())

            ForEach(Array(panel.targets.enumerated()), id: \.element.id) { index, target in
                targetEditor(index: index, target: target)
            }

            if panel.targets.isEmpty {
                targetEditor(index: 0, target: PanelTarget(refId: "A", metric: panel.metric))
                    .onAppear {
                        panel.targets = [PanelTarget(refId: "A", metric: panel.metric)]
                    }
            }

            // Add query button
            Button {
                let nextRef = String(UnicodeScalar(65 + panel.targets.count)!) // A, B, C...
                panel.targets.append(PanelTarget(refId: nextRef, metric: panel.metric))
            } label: {
                Label(L.tr("쿼리 추가", "Add query"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Divider()

            // PromQL reference
            Text(L.tr("PromQL 참고", "PromQL Reference"))
                .font(.subheadline.bold())

            Text(panel.effectiveMetric.defaultQuery)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func targetEditor(index: Int, target: PanelTarget) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Metric picker
                HStack {
                    Text(L.tr("지표", "Metric"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)

                    Picker("", selection: Binding(
                        get: { panel.targets.indices.contains(index) ? panel.targets[index].metric : target.metric },
                        set: { newMetric in
                            if panel.targets.indices.contains(index) {
                                panel.targets[index].metric = newMetric
                            }
                        }
                    )) {
                        ForEach(PanelMetric.allCases.filter { $0.compatiblePanelTypes.contains(panel.panelType) },
                                id: \.rawValue) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Custom query field
                HStack {
                    Text(L.tr("쿼리", "Query"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)

                    TextField(
                        L.tr("커스텀 PromQL (선택)", "Custom PromQL (optional)"),
                        text: Binding(
                            get: { panel.targets.indices.contains(index) ? (panel.targets[index].query ?? "") : "" },
                            set: { newQuery in
                                if panel.targets.indices.contains(index) {
                                    panel.targets[index].query = newQuery.isEmpty ? nil : newQuery
                                }
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                }
            }
        } label: {
            HStack {
                Text(target.refId)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))

                Spacer()

                if panel.targets.count > 1 {
                    Button(role: .destructive) {
                        panel.targets.removeAll { $0.id == target.id }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Visualization Tab

    private var visualizationTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Panel type picker
            Text(L.tr("패널 종류", "Panel type"))
                .font(.subheadline.bold())

            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                GridItem(.flexible()), GridItem(.flexible()),
            ], spacing: 8) {
                ForEach(PanelType.allCases, id: \.rawValue) { type in
                    Button {
                        panel.panelType = type
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: type.icon)
                                .font(.title3)
                            Text(type.displayName)
                                .font(.system(size: 9))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            panel.panelType == type
                                ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                                : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Display options based on panel type
            switch panel.panelType {
            case .stat:
                statDisplayOptions
            case .timeSeries:
                timeSeriesDisplayOptions
            case .barChart:
                barChartDisplayOptions
            case .table:
                tableDisplayOptions
            case .gauge:
                gaugeDisplayOptions
            }
        }
    }

    // MARK: - Display Options per Type

    private var statDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.tr("색상 모드", "Color mode"))
                .font(.subheadline.bold())
            Picker("", selection: $panel.options.colorMode) {
                ForEach(PanelDisplayOptions.ColorMode.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(L.tr("그래프 모드", "Graph mode"))
                .font(.subheadline.bold())
            Picker("", selection: $panel.options.graphMode) {
                ForEach(PanelDisplayOptions.GraphMode.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var timeSeriesDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("범례 표시", "Show legend"), isOn: $panel.options.showLegend)

            if panel.options.showLegend {
                Picker(L.tr("범례 위치", "Legend position"), selection: $panel.options.legendPosition) {
                    ForEach(PanelDisplayOptions.LegendPosition.allCases, id: \.rawValue) { pos in
                        Text(pos.rawValue.capitalized).tag(pos)
                    }
                }
            }

            Picker(L.tr("툴팁 모드", "Tooltip mode"), selection: $panel.options.tooltipMode) {
                ForEach(PanelDisplayOptions.TooltipMode.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }

            HStack {
                Text(L.tr("선 두께", "Line width"))
                Slider(value: $panel.options.lineWidth, in: 1...5, step: 1)
                Text(String(format: "%.0f", panel.options.lineWidth))
                    .font(.caption.monospacedDigit())
            }

            HStack {
                Text(L.tr("채우기", "Fill opacity"))
                Slider(value: $panel.options.fillOpacity, in: 0...1, step: 0.1)
                Text(String(format: "%.0f%%", panel.options.fillOpacity * 100))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var barChartDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("범례 표시", "Show legend"), isOn: $panel.options.showLegend)

            Picker(L.tr("툴팁 모드", "Tooltip mode"), selection: $panel.options.tooltipMode) {
                ForEach(PanelDisplayOptions.TooltipMode.allCases, id: \.rawValue) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
        }
    }

    private var tableDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("헤더 표시", "Show header"), isOn: $panel.options.showHeader)
        }
    }

    private var gaugeDisplayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("임계값 표시", "Show thresholds"), isOn: $panel.options.showThresholdMarkers)
        }
    }

    // MARK: - Options Tab

    private var optionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Description
            Text(L.tr("설명", "Description"))
                .font(.subheadline.bold())

            TextField(
                L.tr("패널 설명 (선택)", "Panel description (optional)"),
                text: Binding(
                    get: { panel.description ?? "" },
                    set: { panel.description = $0.isEmpty ? nil : $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...6)

            Divider()

            // Unit
            Text(L.tr("단위", "Unit"))
                .font(.subheadline.bold())

            TextField(
                L.tr("예: tokens, $, %", "e.g. tokens, $, %"),
                text: Binding(
                    get: { panel.options.unit ?? "" },
                    set: { panel.options.unit = $0.isEmpty ? nil : $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            // Decimals
            HStack {
                Text(L.tr("소수점 자릿수", "Decimals"))
                    .font(.subheadline.bold())
                Spacer()
                TextField("auto", value: $panel.options.decimals, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }

            Divider()

            // Thresholds
            Text(L.tr("임계값", "Thresholds"))
                .font(.subheadline.bold())

            ForEach(Array(panel.options.thresholds.enumerated()), id: \.offset) { index, threshold in
                HStack {
                    TextField(L.tr("값", "Value"), value: Binding(
                        get: { panel.options.thresholds[index].value },
                        set: { panel.options.thresholds[index].value = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)

                    TextField(L.tr("색상", "Color"), text: Binding(
                        get: { panel.options.thresholds[index].color },
                        set: { panel.options.thresholds[index].color = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button(role: .destructive) {
                        panel.options.thresholds.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                panel.options.thresholds.append(ThresholdStep(value: 0, color: "red"))
            } label: {
                Label(L.tr("임계값 추가", "Add threshold"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }
}
