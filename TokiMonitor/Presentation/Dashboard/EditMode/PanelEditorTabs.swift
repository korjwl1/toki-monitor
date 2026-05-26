import SwiftUI

// Extracted from `PanelEditorView.swift` (was ~620 lines). Each tab is
// now an independent SwiftUI view bound to the editor's `panel` via
// `@Binding`. Editor lifecycle, header, sidebar, and preview stay in
// `PanelEditorView`; the tab contents live here.

// MARK: - Query Tab

struct PanelEditorQueryTab: View {
    @Binding var panel: PanelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Button {
                // A, B, C, ... up to Z. UnicodeScalar(...) returns nil above
                // U+007F so cap at 26 to avoid the previous force-unwrap
                // crash when the 27th target was added.
                let next = min(65 + panel.targets.count, 90)
                let refId = String(UnicodeScalar(next) ?? UnicodeScalar(65)!)
                panel.targets.append(PanelTarget(refId: refId, metric: panel.metric))
            } label: {
                Label(L.tr("쿼리 추가", "Add query"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Divider()

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
}

// MARK: - Visualization Tab

struct PanelEditorVisualizationTab: View {
    @Binding var panel: PanelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.tr("패널 종류", "Panel type"))
                .font(.subheadline.bold())

            LazyVGrid(columns: [
                GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                GridItem(.flexible()), GridItem(.flexible()),
            ], spacing: 8) {
                ForEach(PanelType.creatableTypes, id: \.rawValue) { type in
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

            switch panel.panelType {
            case .stat:       statOptions
            case .timeSeries: timeSeriesOptions
            case .barChart:   barChartOptions
            case .table:      tableOptions
            case .gauge:      gaugeOptions
            case .pieChart, .rowPanel: EmptyView()
            }
        }
    }

    private var statOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.tr("색상 모드", "Color mode"))
                .font(.subheadline.bold())
            Picker("", selection: $panel.options.colorMode) {
                ForEach(PanelDisplayOptions.ColorMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(L.tr("그래프 모드", "Graph mode"))
                .font(.subheadline.bold())
            Picker("", selection: $panel.options.graphMode) {
                ForEach(PanelDisplayOptions.GraphMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var timeSeriesOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("범례 표시", "Show legend"), isOn: $panel.options.showLegend)

            if panel.options.showLegend {
                Picker(L.tr("범례 위치", "Legend position"), selection: $panel.options.legendPosition) {
                    ForEach(PanelDisplayOptions.LegendPosition.allCases, id: \.rawValue) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
            }

            Picker(L.tr("툴팁 모드", "Tooltip mode"), selection: $panel.options.tooltipMode) {
                ForEach(PanelDisplayOptions.TooltipMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
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

    private var barChartOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("범례 표시", "Show legend"), isOn: $panel.options.showLegend)

            Picker(L.tr("툴팁 모드", "Tooltip mode"), selection: $panel.options.tooltipMode) {
                ForEach(PanelDisplayOptions.TooltipMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    private var tableOptions: some View {
        Toggle(L.tr("헤더 표시", "Show header"), isOn: $panel.options.showHeader)
    }

    private var gaugeOptions: some View {
        Toggle(L.tr("임계값 표시", "Show thresholds"), isOn: $panel.options.showThresholdMarkers)
    }
}

// MARK: - Options Tab

struct PanelEditorOptionsTab: View {
    @Binding var panel: PanelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            HStack {
                Text(L.tr("소수점 자릿수", "Decimals"))
                    .font(.subheadline.bold())
                Spacer()
                TextField("auto", value: $panel.options.decimals, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }

            Divider()

            Text(L.tr("임계값", "Thresholds"))
                .font(.subheadline.bold())

            ForEach(panel.options.thresholds) { threshold in
                if let index = panel.options.thresholds.firstIndex(where: { $0.id == threshold.id }) {
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

// MARK: - Data Links Tab

struct PanelEditorDataLinksTab: View {
    @Binding var panel: PanelConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.dash.dataLinks)
                .font(.subheadline.bold())

            ForEach(Array(panel.dataLinks.enumerated()), id: \.element.id) { index, _ in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L.dash.linkTitle)
                                .font(.caption)
                                .frame(width: 50, alignment: .leading)
                            TextField(L.dash.linkTitle, text: Binding(
                                get: { panel.dataLinks[index].title },
                                set: { panel.dataLinks[index].title = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text(L.dash.linkURL)
                                .font(.caption)
                                .frame(width: 50, alignment: .leading)
                            TextField(L.dash.linkURL, text: Binding(
                                get: { panel.dataLinks[index].url },
                                set: { panel.dataLinks[index].url = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        }
                        Toggle(L.tr("탐색에서 열기", "Open in Explore"), isOn: Binding(
                            get: { panel.dataLinks[index].openInExplore },
                            set: { panel.dataLinks[index].openInExplore = $0 }
                        ))
                        .font(.caption)
                    }
                } label: {
                    HStack {
                        Image(systemName: "link")
                            .font(.caption)
                        Spacer()
                        Button(role: .destructive) {
                            panel.dataLinks.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                panel.dataLinks.append(DataLink(title: "", url: ""))
            } label: {
                Label(L.dash.addLink, systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Divider()

            Text(L.tr("URL 템플릿 변수", "URL template variables"))
                .font(.caption.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text("${__from} - " + L.tr("시작 시간", "Start time"))
                Text("${__to} - " + L.tr("종료 시간", "End time"))
                Text("${variable_name} - " + L.tr("대시보드 변수 값", "Dashboard variable value"))
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}
