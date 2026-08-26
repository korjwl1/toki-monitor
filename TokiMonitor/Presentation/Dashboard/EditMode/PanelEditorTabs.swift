import SwiftUI

// Extracted from `PanelEditorView.swift` (was ~620 lines). Each tab is
// now an independent SwiftUI view bound to the editor's `panel` via
// `@Binding`. Editor lifecycle, header, sidebar, and preview stay in
// `PanelEditorView`; the tab contents live here.

// MARK: - Query Tab

struct PanelEditorQueryTab: View {
    @Binding var panel: PanelConfig
    /// Which backend the queries will be sent to. The two accept different
    /// subsets, so a verdict is only meaningful against one of them
    /// (contract Q3).
    var backend: QueryBackend = .local
    /// Needed to check what will actually be SENT: `$__interval` and the rest
    /// are resolved before the backend ever sees the query.
    var time: TimeConfig = TimeConfig()
    var variables: [DashboardVariable] = []

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
                // The "only query A is run" warning that stood here is gone
                // because it is no longer true: `PanelFetchCoordinator`
                // executes every refId (contract Q5). Leaving a warning up
                // after the defect it described is fixed teaches the reader to
                // ignore warnings.
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

                validationNotice(for: index, target: target)
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

                // Hide runs the query and leaves it out of the drawing, so a
                // reader can silence one series without losing it — and without
                // the panel pretending the query was never written.
                if panel.targets.indices.contains(index) {
                    let hidden = panel.targets[index].hide
                    Button {
                        panel.targets[index].hide.toggle()
                    } label: {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(hidden ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(hidden
                          ? L.tr("실행하지만 그리지 않습니다", "Executed, but not drawn")
                          : L.tr("이 쿼리를 숨깁니다", "Hide this query"))
                }

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

    /// What the selected backend will make of this query, before it is sent.
    ///
    /// Advisory, not a gate: the daemon owns the query language and the check
    /// here only describes it, so a query it dislikes is still sent and the
    /// backend's own answer is what the panel shows. A wrong warning costs a
    /// glance; a wrong refusal costs a query that would have worked.
    @ViewBuilder
    private func validationNotice(for index: Int, target: PanelTarget) -> some View {
        let written = panel.targets.indices.contains(index)
            ? panel.targets[index].query : target.query
        let metric = panel.targets.indices.contains(index)
            ? panel.targets[index].metric : target.metric
        let template = (written?.isEmpty == false ? written! : metric.defaultQuery)
        let result = QueryValidation.check(template: template, time: time,
                                           variables: variables, backend: backend)
        if !result.validation.isValid, let reason = result.validation.reason {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption2)
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
            case .stateTimeline: stateTimelineOptions
            case .pieChart, .rowPanel, .unknown: EmptyView()
            }
        }
    }

    /// The colour-mode and graph-mode pickers used to live here. Neither
    /// reached the render — a stat card is a number and a subtitle, with no
    /// sparkline to switch on and no threshold colouring to apply — so under
    /// contract R1 they are not offered. They will come back with the
    /// threshold work that gives them something to do.
    private var statOptions: some View {
        Text(L.tr("스탯 패널의 표시는 단위와 소수 자릿수로 정합니다 — 옵션 탭에 있습니다.",
                  "A stat panel is styled by its unit and decimals, on the Options tab."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L.tr("임계값 밴드 표시", "Show threshold bands"),
                   isOn: $panel.options.showThresholdMarkers)

            // A dial with no stated ends is decoration. Left blank the panel
            // derives them — from the thresholds, or from a round ceiling
            // above the value — and prints whichever it used under the arc.
            HStack {
                Text(L.tr("최소", "Min"))
                    .font(.caption)
                    .frame(width: 40, alignment: .leading)
                TextField(L.tr("0", "0"), value: $panel.options.gaugeMin, format: .number)
                    .textFieldStyle(.roundedBorder)
                Text(L.tr("최대", "Max"))
                    .font(.caption)
                    .frame(width: 40, alignment: .trailing)
                TextField(L.tr("자동", "auto"), value: $panel.options.gaugeMax, format: .number)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// A continuous measure has a different value in every sample, so merging
    /// spans by exact value would draw one span per sample. Thresholds are
    /// what turn it into a handful of states — which is why the panel says so
    /// here rather than silently drawing stripes.
    private var stateTimelineOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.tr("연속된 같은 상태끼리 하나의 구간으로 합쳐집니다.",
                      "Consecutive samples in the same state merge into one span."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if panel.options.thresholds.isEmpty {
                Text(L.tr("임계값이 없으면 값이 그대로 상태가 됩니다 — 연속적인 수치라면 옵션 탭에서 임계값을 지정하세요.",
                          "With no thresholds each distinct value is its own state — set thresholds in the Options tab for a continuous measure."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Options Tab

struct PanelEditorOptionsTab: View {
    @Binding var panel: PanelConfig
    /// The dashboard's variables, for the repeat picker. A repeat names one of
    /// them, so the choice has to be the real list rather than a text field
    /// where a typo produces a panel that simply does not repeat.
    var variables: [DashboardVariable] = []

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

            // Was a free-text field. Anything the formatter did not recognise
            // fell through to a default that ignored it, so "$" or "토큰"
            // typed by hand changed nothing — the failure R1 exists to stop.
            Picker("", selection: Binding(
                get: { panel.options.unit ?? "" },
                set: { panel.options.unit = $0.isEmpty ? nil : $0 }
            )) {
                Text(L.tr("기본", "Default")).tag("")
                ForEach(FieldFormatter.knownUnits, id: \.id) { unit in
                    Text(unit.label).tag(unit.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text(L.tr("소수점 자릿수", "Decimals"))
                    .font(.subheadline.bold())
                Spacer()
                TextField("auto", value: $panel.options.decimals, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }

            if honoursThresholds {
                Divider()
                thresholdEditor
            }

            Divider()
            repeatEditor
        }
    }

    // MARK: - Repeat

    /// Which variable turns this one panel into one panel per value.
    ///
    /// The list is the dashboard's own variables plus "none". A repeat over a
    /// variable that is not multi-select draws exactly one panel — true, and
    /// almost certainly not what the person picking it wanted — so that is
    /// said next to the picker rather than discovered afterwards.
    @ViewBuilder
    private var repeatEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.tr("반복", "Repeat"))
                .font(.subheadline.bold())

            Picker("", selection: Binding(
                get: { panel.repeat ?? "" },
                set: { panel.repeat = $0.isEmpty ? nil : $0 }
            )) {
                Text(L.tr("반복 안 함", "No repeat")).tag("")
                ForEach(variables, id: \.id) { variable in
                    Text("$\(variable.name)").tag(variable.name)
                }
            }
            .pickerStyle(.menu)

            if let name = panel.repeat, !name.isEmpty {
                Picker("", selection: Binding(
                    get: { panel.repeatDirection ?? .horizontal },
                    set: { panel.repeatDirection = $0 }
                )) {
                    Text(L.tr("가로", "Horizontal")).tag(RepeatDirection.horizontal)
                    Text(L.tr("세로", "Vertical")).tag(RepeatDirection.vertical)
                }
                .pickerStyle(.segmented)

                Text(repeatNote(for: name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What this repeat will actually do, in the dashboard as it stands.
    private func repeatNote(for name: String) -> String {
        guard let variable = variables.first(where: { $0.name == name }) else {
            return L.tr("이 대시보드에 `\(name)` 변수가 없습니다. 패널은 하나만 그려집니다.",
                        "This dashboard has no variable named `\(name)`. The panel is drawn once.")
        }
        guard variable.multi || variable.includeAll else {
            return L.tr("`\(name)`는 값을 하나만 고를 수 있는 변수입니다. 반복은 다중 선택 변수에서만 여러 패널이 됩니다.",
                        "`\(name)` is a single-select variable. Repeat only produces several panels from a multi-value variable.")
        }
        let count = VariableResolver.repeatValues(for: variable).count
        guard count > 0 else {
            return L.tr("`\(name)`에 지금 선택된 값이 없어 패널은 하나만 그려집니다.",
                        "`\(name)` has no values selected right now, so the panel is drawn once.")
        }
        return L.tr("지금 선택된 값 \(count)개마다 패널이 하나씩 그려집니다.",
                    "One panel per selected value — \(count) right now.")
    }

    /// Thresholds colour a gauge's bands and a state timeline's spans. Nothing
    /// else reads them yet, so nothing else offers them (contract R1).
    private var honoursThresholds: Bool {
        panel.panelType == .gauge || panel.panelType == .stateTimeline
    }

    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
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
