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

    /// Colour mode is back, because the threshold work gave it something to do:
    /// a stat card now reads its own thresholds and can tint the number or wash
    /// the card with the band it is in. Graph mode is still absent — there is no
    /// sparkline to switch on, and offering the picker would be the R1 failure.
    private var statOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L.tr("임계값 색 적용", "Threshold colour"), selection: $panel.options.colorMode) {
                Text(L.tr("값", "Value")).tag(PanelDisplayOptions.ColorMode.value)
                Text(L.tr("배경", "Background")).tag(PanelDisplayOptions.ColorMode.background)
                Text(L.tr("없음", "None")).tag(PanelDisplayOptions.ColorMode.none)
            }
            .pickerStyle(.segmented)

            Text(panel.options.thresholds.isEmpty
                 ? L.tr("임계값이 없으면 색을 바꿀 근거가 없습니다 — 옵션 탭에서 지정하세요.",
                        "With no thresholds there is nothing to colour by — set them on the Options tab.")
                 : L.tr("나머지 표시는 단위와 소수 자릿수로 정합니다 — 옵션 탭에 있습니다.",
                        "The rest of a stat panel is styled by its unit and decimals, on the Options tab."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 8) {
            // The band toggle moved to the threshold editor on the Options tab,
            // next to the steps it switches on and off. Two controls for one
            // setting, on two tabs, is how a reader ends up sure they turned it
            // on somewhere.

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

            if panel.panelType.honoursValueMappings {
                Divider()
                valueMappingEditor
            }

            Divider()
            overrideEditor

            Divider()
            panelTimeEditor

            Divider()
            repeatEditor
        }
    }

    // MARK: - Panel time (FR-037)

    /// A window for this panel alone.
    ///
    /// Both controls are pickers over a closed list rather than text fields: a
    /// token that does not parse leaves the panel silently on the dashboard's
    /// window, and "I typed 7days and nothing happened" is precisely the
    /// failure a picker cannot produce.
    private var panelTimeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.tr("패널 시간", "Panel time"))
                .font(.subheadline.bold())

            HStack {
                Text(L.tr("상대 시간", "Relative time"))
                    .font(.caption)
                    .frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { panel.relativeTime ?? "" },
                    set: { panel.relativeTime = $0.isEmpty ? nil : $0 }
                )) {
                    Text(L.tr("대시보드 따름", "Follow dashboard")).tag("")
                    ForEach(PanelTimeOverride.suggestedTokens, id: \.self) { token in
                        Text(L.tr("최근 \(token)", "last \(token)")).tag(token)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            HStack {
                Text(L.tr("시간 이동", "Time shift"))
                    .font(.caption)
                    .frame(width: 96, alignment: .leading)
                Picker("", selection: Binding(
                    get: { panel.timeShift ?? "" },
                    set: { panel.timeShift = $0.isEmpty ? nil : $0 }
                )) {
                    Text(L.tr("이동 없음", "No shift")).tag("")
                    ForEach(PanelTimeOverride.suggestedTokens, id: \.self) { token in
                        Text(L.tr("\(token) 전", "\(token) earlier")).tag(token)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if let label = PanelTimeOverride.label(for: panel) {
                Label(
                    L.tr("이 패널은 대시보드 시간 범위를 따르지 않습니다 (\(label)). 패널 제목 옆에 그렇게 표시됩니다.",
                         "This panel will not follow the dashboard's time range (\(label)). It says so beside its title."),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(DS.bodySecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            // A token off a dashboard written elsewhere that this build cannot
            // read. Kept on disk (계약 C1) and named here rather than silently
            // dropped from the picker above.
            ForEach(PanelTimeOverride.invalidTokens(of: panel), id: \.self) { token in
                Label(
                    L.tr("`\(token)`을(를) 읽을 수 없어 무시합니다. 저장할 때는 그대로 보존됩니다.",
                         "`\(token)` cannot be read and is ignored. It is kept as written when saving."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(DS.threshold(.orange))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Field overrides

    /// Rules that give one field different display settings from the rest.
    ///
    /// The resolver and its four matchers have been here, with tests, since the
    /// frame contract landed. There was no way to write a rule, so the feature
    /// existed only in the JSON — which is why this is a list editor and not a
    /// new mechanism.
    ///
    /// Each rule offers only the properties this panel type's render actually
    /// reads (계약 R1). On a gauge that is formatting and the ends of the dial;
    /// on a line chart it is all six; on a state timeline it is the row name.
    @ViewBuilder
    private var overrideEditor: some View {
        let honoured = panel.panelType.honouredFieldProperties
        VStack(alignment: .leading, spacing: 12) {
            Text(L.tr("필드 오버라이드", "Field overrides"))
                .font(.subheadline.bold())

            if honoured.isEmpty {
                Text(L.tr("이 패널 종류는 필드별 표시 설정을 반영하지 않습니다.",
                          "This panel type does not read per-field display settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L.tr("위에서 정한 설정 위에 얹는 규칙입니다. 아래쪽 규칙이 위쪽을 이깁니다.",
                          "Rules layered over the settings above. A later rule wins over an earlier one."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(overrideIndices, id: \.self) { index in
                    overrideRow(index: index, honoured: honoured)
                }

                Button {
                    var config = panel.fieldConfig ?? FieldConfigSource()
                    config.overrides.append(
                        FieldOverride(matcher: .byName(""), config: FieldDisplayConfig())
                    )
                    panel.fieldConfig = config
                } label: {
                    Label(L.tr("규칙 추가", "Add rule"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var overrideIndices: [Int] {
        Array((panel.fieldConfig?.overrides ?? []).indices)
    }

    private func overrideBinding(_ index: Int) -> Binding<FieldOverride> {
        Binding(
            get: {
                guard let overrides = panel.fieldConfig?.overrides,
                      overrides.indices.contains(index) else {
                    // A row can outlive its rule by one layout pass after a
                    // delete. An empty stand-in draws nothing and writes
                    // nothing, where an index would trap.
                    return FieldOverride(matcher: .byName(""), config: FieldDisplayConfig())
                }
                return overrides[index]
            },
            set: { newValue in
                guard var config = panel.fieldConfig,
                      config.overrides.indices.contains(index) else { return }
                config.overrides[index] = newValue
                panel.fieldConfig = config
            }
        )
    }

    private func overrideRow(index: Int, honoured: Set<FieldDisplayProperty>) -> some View {
        let rule = overrideBinding(index)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                matcherEditor(rule)
                Divider()
                propertyEditor(rule, honoured: honoured)
            }
        } label: {
            HStack {
                Text(L.tr("규칙 \(index + 1)", "Rule \(index + 1)"))
                    .font(.caption.bold())
                Spacer()
                // Order is the rule, so moving one is an edit, not a
                // convenience: a later rule beats an earlier one.
                Button {
                    move(index, by: -1)
                } label: {
                    Image(systemName: "arrow.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button {
                    move(index, by: 1)
                } label: {
                    Image(systemName: "arrow.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == overrideIndices.count - 1)

                Button(role: .destructive) {
                    guard var config = panel.fieldConfig,
                          config.overrides.indices.contains(index) else { return }
                    config.overrides.remove(at: index)
                    panel.fieldConfig = config.overrides.isEmpty && config.defaults.isEmpty
                        ? nil : config
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        guard var config = panel.fieldConfig else { return }
        let target = index + offset
        guard config.overrides.indices.contains(index),
              config.overrides.indices.contains(target) else { return }
        config.overrides.swapAt(index, target)
        panel.fieldConfig = config
    }

    // MARK: Matchers

    /// All four matchers the resolver implements. Which one is chosen decides
    /// what the second control asks for, because "which fields" is a different
    /// question for a name than for a label pair.
    @ViewBuilder
    private func matcherEditor(_ rule: Binding<FieldOverride>) -> some View {
        HStack {
            Text(L.tr("대상", "Applies to"))
                .font(.caption)
                .frame(width: 72, alignment: .leading)

            Picker("", selection: Binding(
                get: { MatcherKind(rule.wrappedValue.matcher) },
                set: { rule.wrappedValue.matcher = $0.emptyMatcher }
            )) {
                ForEach(MatcherKind.allCases, id: \.rawValue) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }

        switch rule.wrappedValue.matcher {
        case let .byName(name):
            matcherField(L.tr("필드 이름", "Field name"), text: name) {
                rule.wrappedValue.matcher = .byName($0)
            }
        case let .byRegex(pattern):
            VStack(alignment: .leading, spacing: 4) {
                matcherField(L.tr("정규식", "Regular expression"), text: pattern) {
                    rule.wrappedValue.matcher = .byRegex($0)
                }
                // An invalid pattern matches nothing, which is silent — so it
                // is said here rather than left to look like "the rule did not
                // work".
                if !pattern.isEmpty,
                   (try? NSRegularExpression(pattern: pattern)) == nil {
                    Text(L.tr("정규식이 올바르지 않아 아무 필드에도 적용되지 않습니다.",
                              "This is not a valid expression, so it matches no field."))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        case let .byLabel(key, value):
            HStack {
                Text(L.tr("라벨", "Label"))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                TextField("provider", text: Binding(
                    get: { key },
                    set: { rule.wrappedValue.matcher = .byLabel(key: $0, value: value) }
                ))
                .textFieldStyle(.roundedBorder)
                Text("=").font(.caption)
                TextField("codex", text: Binding(
                    get: { value },
                    set: { rule.wrappedValue.matcher = .byLabel(key: key, value: $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        case .allNumeric:
            Text(L.tr("이 패널이 그리는 모든 수치 필드에 적용됩니다.",
                      "Applies to every numeric field this panel draws."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func matcherField(_ prompt: String, text: String,
                              set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(prompt)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            TextField(prompt, text: Binding(get: { text }, set: set))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    /// The four matchers, flattened so a picker can name them. The resolver's
    /// own enum carries associated values, which a `Picker` selection cannot.
    private enum MatcherKind: String, CaseIterable {
        case byName, byRegex, byLabel, allNumeric

        init(_ matcher: FieldMatcher) {
            switch matcher {
            case .byName:     self = .byName
            case .byRegex:    self = .byRegex
            case .byLabel:    self = .byLabel
            case .allNumeric: self = .allNumeric
            }
        }

        var emptyMatcher: FieldMatcher {
            switch self {
            case .byName:     return .byName("")
            case .byRegex:    return .byRegex("")
            case .byLabel:    return .byLabel(key: "", value: "")
            case .allNumeric: return .allNumeric
            }
        }

        var label: String {
            switch self {
            case .byName:     return L.tr("필드 이름", "Field name")
            case .byRegex:    return L.tr("이름 정규식", "Name matches regex")
            case .byLabel:    return L.tr("라벨 일치", "Label equals")
            case .allNumeric: return L.tr("모든 수치 필드", "All numeric fields")
            }
        }
    }

    // MARK: Properties

    @ViewBuilder
    private func propertyEditor(_ rule: Binding<FieldOverride>,
                                honoured: Set<FieldDisplayProperty>) -> some View {
        if honoured.contains(.displayName) {
            HStack {
                Text(FieldDisplayProperty.displayName.label)
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                TextField("{{project}}", text: Binding(
                    get: { rule.wrappedValue.config.displayName ?? "" },
                    set: { rule.wrappedValue.config.displayName = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            Text(L.tr("`{{라벨}}`은 그 계열의 라벨 값으로 채워집니다.",
                      "`{{label}}` is filled from that series' own labels."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if honoured.contains(.unit) {
            HStack {
                Text(FieldDisplayProperty.unit.label)
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(
                    get: { rule.wrappedValue.config.unit ?? "" },
                    set: { rule.wrappedValue.config.unit = $0.isEmpty ? nil : $0 }
                )) {
                    Text(L.tr("바꾸지 않음", "Unchanged")).tag("")
                    ForEach(FieldFormatter.knownUnits, id: \.id) { unit in
                        Text(unit.label).tag(unit.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }

        if honoured.contains(.decimals) {
            HStack {
                Text(FieldDisplayProperty.decimals.label)
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                TextField(L.tr("자동", "auto"), value: rule.config.decimals, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer()
            }
        }

        if honoured.contains(.color) {
            HStack {
                Text(FieldDisplayProperty.color.label)
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                // The same measured set the thresholds use. A free string here
                // would be a second unverifiable colour input beside the one R6
                // just closed.
                Picker("", selection: Binding(
                    get: { rule.wrappedValue.config.color.flatMap(ThresholdColor.named) },
                    set: { rule.wrappedValue.config.color = $0?.rawValue }
                )) {
                    Text(L.tr("바꾸지 않음", "Unchanged")).tag(ThresholdColor?.none)
                    ForEach(ThresholdColor.allCases, id: \.rawValue) { token in
                        HStack(spacing: DS.xs) {
                            Circle().fill(DS.threshold(token)).frame(width: 10, height: 10)
                            Text(token.displayName)
                        }
                        .tag(ThresholdColor?.some(token))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)

                if let raw = rule.wrappedValue.config.color,
                   ThresholdColor.named(raw) == nil {
                    Text(raw)
                        .font(.system(size: DS.fontTiny, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help(L.tr("다른 도구에서 온 색입니다. 그대로 그리고, 여기서 고르면 대체됩니다.",
                                   "A colour from another tool. It is drawn as written, and picking one here replaces it."))
                }
                Spacer()
            }
        }

        if honoured.contains(.min) || honoured.contains(.max) {
            HStack {
                Text(L.tr("범위", "Range"))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                if honoured.contains(.min) {
                    TextField(FieldDisplayProperty.min.label, value: rule.config.min,
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                }
                if honoured.contains(.max) {
                    TextField(FieldDisplayProperty.max.label, value: rule.config.max,
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }
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

    /// Thresholds colour a stat card's number, a gauge's bands, a line chart's
    /// rules and a state timeline's spans. Anything else does not read them, so
    /// does not offer them (contract R1).
    private var honoursThresholds: Bool { panel.panelType.honoursThresholds }

    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.tr("임계값", "Thresholds"))
                    .font(.subheadline.bold())
                Spacer()
                Toggle(L.tr("표시", "Show"), isOn: $panel.options.showThresholdMarkers)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            // Percentage needs something to be a percentage of. A stat card is
            // one number and a state timeline is a row of spans; neither has a
            // scale, so the mode is not offered there rather than offered and
            // ignored.
            if panel.panelType.supportsPercentageThresholds {
                Picker("", selection: $panel.options.thresholdMode) {
                    ForEach(ThresholdMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(percentageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Steps, highest first — the way they are read, and the way the
            // resolver applies them.
            ForEach(sortedThresholdIDs, id: \.self) { id in
                if let index = panel.options.thresholds.firstIndex(where: { $0.id == id }) {
                    thresholdRow(index: index)
                }
            }

            // The band below every step. It had no colour of its own before, so
            // a value sitting under the lowest threshold said nothing.
            HStack {
                Text(L.tr("기준", "Base"))
                    .font(.caption)
                    .frame(width: 56, alignment: .leading)
                thresholdColorPicker(
                    selection: $panel.options.thresholdBase,
                    label: L.tr("기준 색", "Base colour")
                )
                Spacer()
                Text(L.tr("모든 단계 아래", "below every step"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                panel.options.thresholds.append(
                    ThresholdStep(value: nextThresholdValue, color: .red)
                )
            } label: {
                Label(L.tr("임계값 추가", "Add threshold"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Value mappings

    /// Rules that replace a value's rendering, ahead of the unit (FR-025).
    ///
    /// In the order they will be applied, first match winning — so the list on
    /// screen reads the way the renderer reads it, and a reader who puts the
    /// specific rule above the general one gets what they arranged.
    private var valueMappingEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.tr("값 매핑", "Value mappings"))
                    .font(.subheadline.bold())
                Spacer()
                Text(L.tr("위에서부터 먼저 적용", "first match wins"))
                    .font(.caption2)
                    .foregroundStyle(DS.bodySecondary)
            }

            if panel.options.valueMappings.isEmpty {
                Text(L.tr("값 매핑은 단위 서식보다 먼저 적용됩니다 — 예: 0을 \"아직 없음\"으로, 값 없음을 \"측정 안 됨\"으로.",
                          "A mapping is applied ahead of the unit — 0 as \"nothing yet\", an absent sample as \"not measured\"."))
                    .font(.caption)
                    .foregroundStyle(DS.bodySecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(panel.options.valueMappings) { mapping in
                if let index = panel.options.valueMappings.firstIndex(where: { $0.id == mapping.id }) {
                    valueMappingRow(index: index)
                }
            }

            Button {
                panel.options.valueMappings.append(
                    ValueMapping(match: .value(0), text: "")
                )
            } label: {
                Label(L.tr("값 매핑 추가", "Add value mapping"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private func valueMappingRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.xs) {
                Picker("", selection: Binding(
                    get: { ValueMappingKind(of: panel.options.valueMappings[index].match) },
                    set: { panel.options.valueMappings[index].match = $0.emptyMatch }
                )) {
                    ForEach(ValueMappingKind.allCases, id: \.rawValue) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                matchFields(index: index)

                Spacer(minLength: 0)

                Button(role: .destructive) {
                    panel.options.valueMappings.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.tr("이 값 매핑 삭제", "Delete this value mapping"))
            }

            HStack(spacing: DS.xs) {
                Text("→").font(.caption).foregroundStyle(DS.bodySecondary)
                TextField(L.tr("표시할 문자열", "Shown instead"),
                          text: Binding(
                            get: { panel.options.valueMappings[index].text },
                            set: { panel.options.valueMappings[index].text = $0 }
                          ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                // Optional, and the text is what carries the meaning either
                // way — colour is never the only carrier (계약 R6).
                Picker("", selection: Binding(
                    get: { panel.options.valueMappings[index].color },
                    set: { panel.options.valueMappings[index].color = $0 }
                )) {
                    Text(L.tr("색 없음", "No colour")).tag(ThresholdColor?.none)
                    ForEach(ThresholdColor.allCases, id: \.rawValue) { token in
                        HStack(spacing: DS.xs) {
                            Circle().fill(DS.threshold(token)).frame(width: 10, height: 10)
                            Text(token.displayName)
                        }
                        .tag(ThresholdColor?.some(token))
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }

    @ViewBuilder
    private func matchFields(index: Int) -> some View {
        switch panel.options.valueMappings[index].match {
        case .value(let number):
            TextField(L.tr("값", "Value"), value: Binding(
                get: { number },
                set: { panel.options.valueMappings[index].match = .value($0) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        case .text(let string):
            TextField(L.tr("문자열", "Text"), text: Binding(
                get: { string },
                set: { panel.options.valueMappings[index].match = .text($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        case .range(let from, let to):
            TextField(L.tr("이상", "From"), value: Binding(
                get: { from },
                set: { panel.options.valueMappings[index].match = .range(from: $0, to: to) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            TextField(L.tr("이하", "To"), value: Binding(
                get: { to },
                set: { panel.options.valueMappings[index].match = .range(from: from, to: $0) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
        case .special(let special):
            Picker("", selection: Binding(
                get: { special },
                set: { panel.options.valueMappings[index].match = .special($0) }
            )) {
                ForEach(ValueMapping.Special.allCases, id: \.rawValue) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    /// Steps in descending order, which is how a threshold list is read: the
    /// worst band at the top. The stored order does not matter — the resolver
    /// sorts — so this is presentation only and reordering is not a control the
    /// reader needs.
    private var sortedThresholdIDs: [UUID] {
        panel.options.thresholds.sorted { $0.value > $1.value }.map(\.id)
    }

    private func thresholdRow(index: Int) -> some View {
        HStack {
            Text(panel.options.thresholdMode == .percentage
                 ? L.tr("≥ %", "≥ %")
                 : L.tr("≥", "≥"))
                .font(.caption)
                .frame(width: 56, alignment: .leading)

            TextField(L.tr("값", "Value"), value: Binding(
                get: { panel.options.thresholds[index].value },
                set: { panel.options.thresholds[index].value = $0 }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)

            thresholdColorPicker(
                selection: Binding(
                    get: { panel.options.thresholds[index].color },
                    set: { panel.options.thresholds[index].color = $0 }
                ),
                label: L.tr("색상", "Colour")
            )

            // A colour this build could not validate is kept on disk but not
            // drawn. Saying so is the difference between "my red went grey" and
            // a bug report.
            if let raw = panel.options.thresholds[index].unknownColorRaw {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(L.tr("`\(raw)` 색은 대비를 확인할 수 없어 그리지 않습니다. 저장할 때는 그대로 보존됩니다.",
                               "`\(raw)` cannot be checked for contrast, so it is not drawn. It is kept as written when saving."))
            }

            Spacer()

            Button(role: .destructive) {
                panel.options.thresholds.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
    }

    /// The closed set, as swatches with names. There is no text field: a free
    /// string cannot be checked against the contrast requirement, and one that
    /// missed simply drew grey (계약 R6, FR-027).
    private func thresholdColorPicker(selection: Binding<ThresholdColor>,
                                      label: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(ThresholdColor.allCases, id: \.rawValue) { token in
                HStack(spacing: DS.xs) {
                    Circle()
                        .fill(DS.threshold(token))
                        .frame(width: 10, height: 10)
                    Text(token.displayName)
                }
                .tag(token)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 130)
    }

    /// One above the current highest, so a second threshold does not land on
    /// top of the first and draw a zero-width band.
    private var nextThresholdValue: Double {
        guard let top = panel.options.thresholds.map(\.value).max() else {
            return panel.options.thresholdMode == .percentage ? 80 : 0
        }
        return panel.options.thresholdMode == .percentage
            ? Swift.min(top + 10, 100)
            : top + 1
    }

    private var percentageNote: String {
        switch panel.options.thresholdMode {
        case .absolute:
            return L.tr("값은 데이터와 같은 단위로 읽습니다.",
                        "Values are read in the data's own unit.")
        case .percentage where panel.panelType == .gauge:
            return L.tr("값은 게이지 최소~최대 구간의 백분율입니다.",
                        "Values are a percentage of the gauge's min–max range.")
        case .percentage:
            return L.tr("값은 지금 그려진 데이터 범위의 백분율입니다.",
                        "Values are a percentage of the range currently drawn.")
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

// MARK: - Transform Tab

/// The panel's transformation pipeline.
///
/// The six transformations and the pipeline that runs them have had tests since
/// the frame contract landed. Until `PanelConfig.transformations` there was
/// nowhere to store a pipeline, so the only one that ever ran was the hardcoded
/// preset for `cacheHitRate`. This is the editor for the stored one — it builds
/// `TransformationStep` values and hands them to the same pipeline, rather than
/// being a second way to transform anything.
struct PanelEditorTransformTab: View {
    @Binding var panel: PanelConfig
    /// This panel's own result. Used for two things: the field names the
    /// pickers offer, and the per-step summary of what went in and what came
    /// out (FR-029). Nil before the first fetch, and the tab says so rather
    /// than offering an empty list of fields as if the query returned none.
    var frames: FrameSet?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.tr("변환", "Transformations"))
                .font(.subheadline.bold())

            Text(L.tr("질의 결과에 위에서 아래 순서로 적용됩니다.",
                      "Applied to the query's result, top to bottom."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if panel.transformations.isEmpty {
                Text(L.tr("아직 변환이 없습니다. 질의 결과가 그대로 그려집니다.",
                          "No transformations yet — the query's result is drawn as it arrives."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(panel.transformations) { step in
                if let index = panel.transformations.firstIndex(where: { $0.id == step.id }) {
                    stepEditor(index: index)
                }
            }

            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(Catalogue.allCases, id: \.rawValue) { entry in
                Button(entry.label) {
                    panel.transformations.append(TransformationStep(kind: entry.newStep))
                }
            }
        } label: {
            Label(L.tr("변환 추가", "Add transformation"), systemImage: "plus")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - One step

    private func stepEditor(index: Int) -> some View {
        let step = panel.transformations[index]
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if step.isUnknown {
                    Text(L.tr("이 버전이 실행할 수 없는 변환입니다. 그대로 보존되며, 아무 것도 바꾸지 않습니다.",
                              "This build cannot run this transformation. It is kept as written and changes nothing."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    options(index: index)
                    stageSummary(index: index)
                }
            }
            .opacity(step.disabled ? 0.5 : 1)
        } label: {
            HStack(spacing: DS.sm) {
                // Off, not gone. Comparing "with and without this step" is the
                // reason a pipeline has a switch at all (FR-028).
                Button {
                    panel.transformations[index].disabled.toggle()
                } label: {
                    Image(systemName: step.disabled ? "circle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(step.disabled ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(step.disabled
                      ? L.tr("이 단계를 다시 켭니다", "Switch this step back on")
                      : L.tr("이 단계를 끕니다 — 지우지 않습니다", "Switch this step off — it is not deleted"))

                Text(Catalogue.label(for: step.kind))
                    .font(.caption.bold())

                Spacer()

                Button { move(index, by: -1) } label: {
                    Image(systemName: "arrow.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button { move(index, by: 1) } label: {
                    Image(systemName: "arrow.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == panel.transformations.count - 1)

                Button(role: .destructive) {
                    panel.transformations.remove(at: index)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard panel.transformations.indices.contains(index),
              panel.transformations.indices.contains(target) else { return }
        panel.transformations.swapAt(index, target)
    }

    /// What went into this step and what came out (FR-029).
    ///
    /// A count rather than a table: the question a pipeline raises is "which
    /// step dropped my series", and series and column counts answer it in one
    /// line per step. A step that changed neither says so, which is the other
    /// half of the same question.
    @ViewBuilder
    private func stageSummary(index: Int) -> some View {
        if let frames {
            let before = staged(upTo: index, from: frames)
            let after = staged(upTo: index + 1, from: frames)
            let inShape = shape(before)
            let outShape = shape(after)
            HStack(spacing: DS.xs) {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(inShape == outShape
                     ? L.tr("\(inShape) — 이 단계는 모양을 바꾸지 않았습니다",
                            "\(inShape) — this step changed neither")
                     : "\(inShape) → \(outShape)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(L.tr("질의 결과가 있어야 입·출력을 볼 수 있습니다.",
                      "Run the query to see what this step takes in and gives out."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The frames as they stand after the first `count` steps, preset included
    /// — the preset runs first at render time and a summary that skipped it
    /// would describe a pipeline nobody executes.
    private func staged(upTo count: Int, from frames: FrameSet) -> FrameSet {
        let seeded = TransformationPipeline.apply(
            PanelPreset.transformations(for: panel.effectiveMetric), to: frames
        )
        return TransformationPipeline.apply(
            steps: Array(panel.transformations.prefix(count)), to: seeded
        )
    }

    private func shape(_ set: FrameSet) -> String {
        let columns = Set(set.frames.flatMap { $0.fields.map(\.name) }).count
        return L.tr("계열 \(set.frames.count)개 · 열 \(columns)개",
                    "\(set.frames.count) series · \(columns) columns")
    }

    /// Field names this panel's result actually has. A picker over them beats a
    /// text field: a transformation naming a column that does not exist is the
    /// most common way a pipeline silently does nothing.
    private var fieldNames: [String] {
        guard let frames else { return [] }
        var seen: [String] = []
        for frame in frames.frames {
            for field in frame.fields where !seen.contains(field.name) {
                seen.append(field.name)
            }
        }
        return seen
    }

    // MARK: - Per-type options

    @ViewBuilder
    private func options(index: Int) -> some View {
        switch panel.transformations[index].kind {
        case let .reduce(t):
            reducerPicker(L.tr("축약", "Reducer"), selection: t.reducer) { reducer in
                var next = t
                next.reducer = reducer
                panel.transformations[index].kind = .reduce(next)
            }

        case let .calculateField(t):
            fieldPicker(L.tr("왼쪽", "Left"), value: t.left) { name in
                var next = t; next.left = name
                panel.transformations[index].kind = .calculateField(next)
            }
            HStack {
                Text(L.tr("연산", "Operation"))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(
                    get: { t.operation },
                    set: { op in
                        var next = t; next.operation = op
                        panel.transformations[index].kind = .calculateField(next)
                    }
                )) {
                    ForEach(CalculateFieldTransformation.Operation.allCases, id: \.rawValue) {
                        Text(operationLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            fieldPicker(L.tr("오른쪽", "Right"), value: t.right) { name in
                var next = t; next.right = name
                panel.transformations[index].kind = .calculateField(next)
            }
            textRow(L.tr("새 열 이름", "New column"), value: t.alias ?? "") { name in
                var next = t; next.alias = name.isEmpty ? nil : name
                panel.transformations[index].kind = .calculateField(next)
            }
            Toggle(L.tr("입력 열을 대체합니다", "Replace the input columns"), isOn: Binding(
                get: { t.replaceFields },
                set: { on in
                    var next = t; next.replaceFields = on
                    panel.transformations[index].kind = .calculateField(next)
                }
            ))
            .font(.caption)

        case let .organize(t):
            if fieldNames.isEmpty {
                Text(L.tr("질의 결과가 있어야 열을 고를 수 있습니다.",
                          "Run the query to choose columns."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(fieldNames, id: \.self) { name in
                HStack {
                    Toggle(isOn: Binding(
                        get: { !t.excluded.contains(name) },
                        set: { keep in
                            var next = t
                            if keep { next.excluded.remove(name) } else { next.excluded.insert(name) }
                            panel.transformations[index].kind = .organize(next)
                        }
                    )) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    TextField(L.tr("이름 바꾸기", "Rename"), text: Binding(
                        get: { t.renamed[name] ?? "" },
                        set: { newName in
                            var next = t
                            if newName.isEmpty { next.renamed[name] = nil }
                            else { next.renamed[name] = newName }
                            panel.transformations[index].kind = .organize(next)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                }
            }

        case let .filterByValue(t):
            fieldPicker(L.tr("열", "Column"), value: t.field) { name in
                var next = t; next.field = name
                panel.transformations[index].kind = .filterByValue(next)
            }
            HStack {
                Text(L.tr("조건", "Keep rows"))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(
                    get: { t.comparison },
                    set: { c in
                        var next = t; next.comparison = c
                        panel.transformations[index].kind = .filterByValue(next)
                    }
                )) {
                    ForEach(FilterByValueTransformation.Comparison.allCases, id: \.rawValue) {
                        Text(comparisonLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                TextField(L.tr("값", "Value"), value: Binding(
                    get: { t.value },
                    set: { v in
                        var next = t; next.value = v
                        panel.transformations[index].kind = .filterByValue(next)
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            }

        case let .sortBy(t):
            fieldPicker(L.tr("기준 열", "Sort by"), value: t.field) { name in
                var next = t; next.field = name
                panel.transformations[index].kind = .sortBy(next)
            }
            reducerPicker(L.tr("축약", "Reducer"), selection: t.reducer) { reducer in
                var next = t; next.reducer = reducer
                panel.transformations[index].kind = .sortBy(next)
            }
            Toggle(L.tr("큰 값부터", "Largest first"), isOn: Binding(
                get: { t.descending },
                set: { on in
                    var next = t; next.descending = on
                    panel.transformations[index].kind = .sortBy(next)
                }
            ))
            .font(.caption)

        case let .limit(t):
            HStack {
                Text(L.tr("계열 수", "Series"))
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                TextField("10", value: Binding(
                    get: { t.count },
                    set: { n in
                        panel.transformations[index].kind = .limit(
                            LimitTransformation(count: Swift.max(0, n))
                        )
                    }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                Spacer()
            }
            Text(L.tr("잘려나간 계열 수는 패널에 표시됩니다.",
                      "How many series were cut is shown on the panel."))
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Shared controls

    private func reducerPicker(_ title: String,
                               selection: ReduceTransformation.Reducer,
                               set: @escaping (ReduceTransformation.Reducer) -> Void)
        -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            Picker("", selection: Binding(get: { selection }, set: set)) {
                ForEach(ReduceTransformation.Reducer.allCases, id: \.rawValue) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    /// A column name, chosen from the ones the query returned when it has
    /// returned any, typed otherwise.
    @ViewBuilder
    private func fieldPicker(_ title: String, value: String,
                             set: @escaping (String) -> Void) -> some View {
        if fieldNames.isEmpty {
            textRow(title, value: value, set: set)
        } else {
            HStack {
                Text(title)
                    .font(.caption)
                    .frame(width: 72, alignment: .leading)
                Picker("", selection: Binding(get: { value }, set: set)) {
                    // A name the query no longer returns stays selectable, and
                    // says so: silently switching the reader's pipeline to a
                    // different column would be worse than showing a stale one.
                    if !value.isEmpty, !fieldNames.contains(value) {
                        Text(L.tr("\(value) (결과에 없음)", "\(value) (not in the result)"))
                            .tag(value)
                    }
                    if value.isEmpty {
                        Text(L.tr("고르세요", "Choose")).tag("")
                    }
                    ForEach(fieldNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private func textRow(_ title: String, value: String,
                         set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 72, alignment: .leading)
            TextField(title, text: Binding(get: { value }, set: set))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func operationLabel(_ op: CalculateFieldTransformation.Operation) -> String {
        switch op {
        case .add:      return L.tr("더하기 (+)", "Add (+)")
        case .subtract: return L.tr("빼기 (−)", "Subtract (−)")
        case .multiply: return L.tr("곱하기 (×)", "Multiply (×)")
        case .divide:   return L.tr("나누기 (÷)", "Divide (÷)")
        }
    }

    private func comparisonLabel(_ c: FilterByValueTransformation.Comparison) -> String {
        switch c {
        case .greater:        return "＞"
        case .greaterOrEqual: return "≥"
        case .less:           return "＜"
        case .lessOrEqual:    return "≤"
        case .equal:          return "="
        case .notEqual:       return "≠"
        }
    }

    /// The transformations offered, and what a fresh one of each looks like.
    private enum Catalogue: String, CaseIterable {
        case reduce, calculateField, organize, filterByValue, sortBy, limit

        var label: String {
            switch self {
            case .reduce:         return L.tr("값 하나로 줄이기", "Reduce to one value")
            case .calculateField: return L.tr("계산 열 추가", "Add a calculated column")
            case .organize:       return L.tr("열 정리", "Organize columns")
            case .filterByValue:  return L.tr("값으로 거르기", "Filter by value")
            case .sortBy:         return L.tr("정렬", "Sort")
            case .limit:          return L.tr("계열 수 제한", "Limit series")
            }
        }

        var newStep: TransformationStep.Kind {
            switch self {
            case .reduce:         return .reduce(ReduceTransformation())
            case .calculateField: return .calculateField(
                CalculateFieldTransformation(left: "", right: "", operation: .add))
            case .organize:       return .organize(OrganizeTransformation())
            case .filterByValue:  return .filterByValue(
                FilterByValueTransformation(field: "", comparison: .greater, value: 0))
            case .sortBy:         return .sortBy(SortByTransformation(field: ""))
            case .limit:          return .limit(LimitTransformation(count: 10))
            }
        }

        static func label(for kind: TransformationStep.Kind) -> String {
            if let entry = Catalogue(rawValue: kind.typeID) { return entry.label }
            return kind.typeID
        }
    }
}


// MARK: - Which kind of match a row is editing

/// The match cases, flattened so a picker can select one.
///
/// `ValueMapping.Match` carries its operand, so it cannot be a picker's
/// selection directly — changing the kind would need an operand to change TO.
/// This is that choice, and `emptyMatch` is the operand a freshly chosen kind
/// starts from.
enum ValueMappingKind: String, CaseIterable, Sendable {
    case value, text, range, special

    init(of match: ValueMapping.Match) {
        switch match {
        case .value:   self = .value
        case .text:    self = .text
        case .range:   self = .range
        case .special: self = .special
        }
    }

    var displayName: String {
        switch self {
        case .value:   return L.tr("값이 같음", "Value is")
        case .text:    return L.tr("문자열이 같음", "Text is")
        case .range:   return L.tr("범위 안", "In range")
        case .special: return L.tr("특수값", "Special")
        }
    }

    var emptyMatch: ValueMapping.Match {
        switch self {
        case .value:   return .value(0)
        case .text:    return .text("")
        case .range:   return .range(from: nil, to: nil)
        case .special: return .special(.absent)
        }
    }
}
