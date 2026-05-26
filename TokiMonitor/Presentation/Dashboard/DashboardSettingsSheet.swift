import SwiftUI

/// Dashboard settings sheet for editing metadata, variables, and viewing JSON model.
struct DashboardSettingsSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    @State private var tagsText: String = ""
    @State private var jsonString: String = ""
    /// Debounce task for text-field keystrokes — instead of writing the
    /// whole dashboard JSON to UserDefaults on every character, coalesce
    /// writes within a short window. On dismiss we flush any pending
    /// save synchronously so closing the sheet never loses an in-flight
    /// edit.
    @State private var pendingSave: Task<Void, Never>?

    enum SettingsTab: String, CaseIterable {
        case general
        case variables
        case json

        var label: String {
            switch self {
            case .general: L.tr("일반", "General")
            case .variables: L.dash.variables
            case .json: L.dash.jsonModel
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .variables: "dollarsign.square"
            case .json: "curlybraces"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.dash.dashboardSettings)
                    .font(.headline)
                Spacer()
                Button(L.dash.done) {
                    flushPendingSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.rawValue) { tab in
                    Button {
                        selectedTab = tab
                        if tab == .json {
                            jsonString = (try? viewModel.dashboardConfig.exportJSONString()) ?? "{}"
                        }
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

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .general:
                        generalTab
                    case .variables:
                        variablesTab
                    case .json:
                        jsonTab
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 500)
        .onAppear {
            tagsText = viewModel.dashboardConfig.tags.joined(separator: ", ")
        }
        .onDisappear { flushPendingSave() }
    }

    /// Coalesce keystroke saves within ~300ms so a fast typist doesn't
    /// re-encode + re-write the entire dashboard JSON on every character.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            viewModel.saveDashboard()
        }
    }

    /// Cancel any pending debounced save and persist immediately. Called
    /// on Done / sheet dismiss so closing the sheet always commits the
    /// latest in-memory edits.
    private func flushPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        viewModel.saveDashboard()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.title)
                    .font(.subheadline.bold())
                TextField(L.dash.title, text: Binding(
                    get: { viewModel.dashboardConfig.title },
                    set: { viewModel.dashboardConfig.title = $0; scheduleSave() }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Description
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.description)
                    .font(.subheadline.bold())
                TextField(L.dash.description, text: Binding(
                    get: { viewModel.dashboardConfig.description ?? "" },
                    set: { viewModel.dashboardConfig.description = $0.isEmpty ? nil : $0; scheduleSave() }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            }

            // Tags
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.tags)
                    .font(.subheadline.bold())
                TextField(L.tr("태그 (쉼표로 구분)", "Tags (comma separated)"), text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tagsText) { _, newValue in
                        viewModel.dashboardConfig.tags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        scheduleSave()
                    }
            }

            Divider()

            // Default time range
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.defaultTimeRange)
                    .font(.subheadline.bold())
                Picker("", selection: Binding(
                    get: { viewModel.dashboardConfig.time.from },
                    set: { viewModel.dashboardConfig.time.from = $0; viewModel.saveDashboard() }
                )) {
                    ForEach(TimeRangePreset.presets) { preset in
                        Text(preset.label).tag(preset.from)
                    }
                }
                .pickerStyle(.menu)
            }

            // Default refresh
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.defaultRefresh)
                    .font(.subheadline.bold())
                Picker("", selection: Binding(
                    get: { viewModel.dashboardConfig.refresh },
                    set: { viewModel.dashboardConfig.refresh = $0; viewModel.saveDashboard() }
                )) {
                    ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Variables Tab

    private var variablesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.dash.variables)
                .font(.subheadline.bold())

            ForEach(viewModel.variables) { variable in
                variableEditor(variable)
            }

            Button {
                viewModel.addVariable(DashboardVariable(
                    name: "new_var",
                    label: "New Variable",
                    type: .custom,
                    query: "value1,value2,value3"
                ))
            } label: {
                Label(L.tr("변수 추가", "Add Variable"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private func variableEditor(_ variable: DashboardVariable) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L.tr("이름", "Name"))
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    TextField("", text: bindingForVariable(variable, \.name))
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text(L.tr("라벨", "Label"))
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    TextField("", text: Binding(
                        get: { variable.label ?? "" },
                        set: { newLabel in
                            mutateVariable(variable.id) { v in
                                v.label = newLabel.isEmpty ? nil : newLabel
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text(L.tr("종류", "Plugin"))
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { variable.plugin?.kind ?? legacyPluginKind(variable) },
                        set: { newKind in
                            mutateVariable(variable.id) { v in
                                let spec = defaultSpecData(for: newKind, currentVariable: v)
                                v.plugin = VariablePluginRef(kind: newKind, spec: spec)
                                // Keep legacy `type` enum aligned for v3 path / older callers.
                                v.type = (newKind == BuiltinVariablePluginKind.interval) ? .interval : .custom
                            }
                            viewModel.refreshVariables()
                        }
                    )) {
                        Text(L.tr("정적 목록", "Static List"))
                            .tag(BuiltinVariablePluginKind.staticList)
                        Text(L.tr("시간 간격", "Interval"))
                            .tag(BuiltinVariablePluginKind.interval)
                        Text(L.tr("PromQL 라벨", "PromQL Label Values"))
                            .tag(BuiltinVariablePluginKind.tokiLabelValues)
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                    Spacer()
                }

                pluginSpecEditor(variable)

                HStack(spacing: 16) {
                    Toggle(L.tr("다중 선택", "Multi"),
                           isOn: bindingForVariable(variable, \.multi))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Toggle(L.tr("전체 옵션", "Include All"),
                           isOn: bindingForVariable(variable, \.includeAll))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Spacer()
                }
            }
        } label: {
            HStack {
                Text("$\(variable.name)")
                    .font(.caption.bold())
                Spacer()
                Button(role: .destructive) {
                    viewModel.removeVariable(id: variable.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Plugin-specific spec editors

    @ViewBuilder
    private func pluginSpecEditor(_ variable: DashboardVariable) -> some View {
        let kind = variable.plugin?.kind ?? legacyPluginKind(variable)
        switch kind {
        case BuiltinVariablePluginKind.staticList:
            staticListSpecEditor(variable)
        case BuiltinVariablePluginKind.interval:
            intervalSpecEditor(variable)
        case BuiltinVariablePluginKind.tokiLabelValues:
            labelValuesSpecEditor(variable)
        default:
            EmptyView()
        }
    }

    private func staticListSpecEditor(_ variable: DashboardVariable) -> some View {
        HStack(alignment: .top) {
            Text(L.tr("값", "Values"))
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            TextField(L.tr("쉼표로 구분", "comma-separated"), text: Binding(
                get: {
                    if let plugin = variable.plugin,
                       let spec = try? JSONDecoder().decode(StaticListVariableSpec.self, from: plugin.spec) {
                        return spec.values.map(\.value).joined(separator: ", ")
                    }
                    return variable.query
                },
                set: { newText in
                    let values = newText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .map { VariableOption(text: $0, value: $0) }
                    let spec = StaticListVariableSpec(values: values)
                    let data = (try? JSONEncoder().encode(spec)) ?? Data()
                    mutateVariable(variable.id) { v in
                        v.query = newText
                        v.options = values
                        v.plugin = VariablePluginRef(
                            kind: BuiltinVariablePluginKind.staticList, spec: data
                        )
                    }
                    viewModel.refreshVariables()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func intervalSpecEditor(_ variable: DashboardVariable) -> some View {
        HStack(alignment: .top) {
            Text(L.tr("간격", "Intervals"))
                .font(.caption)
                .frame(width: 60, alignment: .leading)
            TextField("1m, 5m, 15m, 1h", text: Binding(
                get: {
                    if let plugin = variable.plugin,
                       let spec = try? JSONDecoder().decode(IntervalVariableSpec.self, from: plugin.spec) {
                        return spec.values.joined(separator: ", ")
                    }
                    return variable.query
                },
                set: { newText in
                    let values = newText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let spec = IntervalVariableSpec(values: values)
                    let data = (try? JSONEncoder().encode(spec)) ?? Data()
                    mutateVariable(variable.id) { v in
                        v.query = newText
                        v.plugin = VariablePluginRef(
                            kind: BuiltinVariablePluginKind.interval, spec: data
                        )
                    }
                    viewModel.refreshVariables()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func labelValuesSpecEditor(_ variable: DashboardVariable) -> some View {
        let currentSpec: TokiLabelValuesVariableSpec = {
            if let plugin = variable.plugin,
               let s = try? JSONDecoder().decode(TokiLabelValuesVariableSpec.self, from: plugin.spec) {
                return s
            }
            return TokiLabelValuesVariableSpec(
                datasource: nil,
                query: "sum by (model) (increase(usage[$__interval]))",
                labelName: "model"
            )
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(L.tr("쿼리", "Query"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                TextField("PromQL", text: Binding(
                    get: { currentSpec.query },
                    set: { newQuery in
                        var s = currentSpec
                        s.query = newQuery
                        writeLabelValuesSpec(s, variableID: variable.id)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            }
            HStack {
                Text(L.tr("라벨", "Label"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: Binding(
                    get: { currentSpec.labelName },
                    set: { newLabel in
                        var s = currentSpec
                        s.labelName = newLabel
                        writeLabelValuesSpec(s, variableID: variable.id)
                    }
                )) {
                    Text("model").tag("model")
                    Text("project").tag("project")
                    Text("device_id").tag("device_id")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
                Spacer()
            }
        }
    }

    private func writeLabelValuesSpec(_ spec: TokiLabelValuesVariableSpec, variableID: UUID) {
        let data = (try? JSONEncoder().encode(spec)) ?? Data()
        mutateVariable(variableID) { v in
            v.plugin = VariablePluginRef(
                kind: BuiltinVariablePluginKind.tokiLabelValues, spec: data
            )
        }
        viewModel.refreshVariables()
    }

    // MARK: - Variable mutation helpers

    private func mutateVariable(_ id: UUID, _ change: (inout DashboardVariable) -> Void) {
        guard let idx = viewModel.dashboardConfig.templating.list.firstIndex(where: { $0.id == id })
        else { return }
        change(&viewModel.dashboardConfig.templating.list[idx])
        scheduleSave()
    }

    /// Binding that reads the latest persisted state of a variable, falling
    /// back to the **captured snapshot** if the variable has just been
    /// removed mid-render. The earlier implementation force-unwrapped
    /// `templating.list.first!` here, which crashed if the last variable
    /// was deleted while SwiftUI was still re-evaluating its editor row.
    private func bindingForVariable<T>(
        _ snapshot: DashboardVariable,
        _ keyPath: WritableKeyPath<DashboardVariable, T>
    ) -> Binding<T> {
        let id = snapshot.id
        return Binding(
            get: {
                viewModel.dashboardConfig.templating.list.first(where: { $0.id == id })?[keyPath: keyPath]
                    ?? snapshot[keyPath: keyPath]
            },
            set: { newValue in mutateVariable(id) { v in v[keyPath: keyPath] = newValue } }
        )
    }

    /// Fall back from the legacy `type` enum to a plugin kind when a
    /// variable has no `plugin` ref yet (pre-v4 imports, etc.).
    private func legacyPluginKind(_ variable: DashboardVariable) -> String {
        switch variable.type {
        case .interval: return BuiltinVariablePluginKind.interval
        case .custom:   return BuiltinVariablePluginKind.staticList
        }
    }

    /// Produce a sensible default plugin spec when the user switches plugin
    /// kinds — preserves data when possible.
    private func defaultSpecData(for kind: String, currentVariable v: DashboardVariable) -> Data {
        let encoder = JSONEncoder()
        switch kind {
        case BuiltinVariablePluginKind.staticList:
            let values = v.options.isEmpty
                ? v.query.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { VariableOption(text: $0, value: $0) }
                : v.options
            return (try? encoder.encode(StaticListVariableSpec(values: values))) ?? Data()
        case BuiltinVariablePluginKind.interval:
            let parsed = v.query.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let values = parsed.isEmpty ? IntervalVariableSpec().values : parsed
            return (try? encoder.encode(IntervalVariableSpec(values: values))) ?? Data()
        case BuiltinVariablePluginKind.tokiLabelValues:
            return (try? encoder.encode(TokiLabelValuesVariableSpec(
                datasource: nil,
                query: "sum by (model) (increase(usage[$__interval]))",
                labelName: "model"
            ))) ?? Data()
        default:
            return Data()
        }
    }

    // MARK: - JSON Tab

    private var jsonTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.dash.jsonModel)
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                } label: {
                    Label(L.tr("복사", "Copy"), systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(jsonString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: .infinity)
        }
    }
}
