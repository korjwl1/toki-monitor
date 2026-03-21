import SwiftUI

/// Dashboard settings sheet for editing metadata, variables, and viewing JSON model.
struct DashboardSettingsSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    @State private var tagsText: String = ""
    @State private var jsonString: String = ""

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
                Button(L.dash.done) { dismiss() }
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
                    set: { viewModel.dashboardConfig.title = $0; viewModel.saveDashboard() }
                ))
                .textFieldStyle(.roundedBorder)
            }

            // Description
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.description)
                    .font(.subheadline.bold())
                TextField(L.dash.description, text: Binding(
                    get: { viewModel.dashboardConfig.description ?? "" },
                    set: { viewModel.dashboardConfig.description = $0.isEmpty ? nil : $0; viewModel.saveDashboard() }
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
                        viewModel.saveDashboard()
                    }
            }

            Divider()

            // Timezone
            VStack(alignment: .leading, spacing: 4) {
                Text(L.dash.timezone)
                    .font(.subheadline.bold())
                Picker("", selection: Binding(
                    get: { viewModel.dashboardConfig.timezone },
                    set: { viewModel.dashboardConfig.timezone = $0; viewModel.saveDashboard() }
                )) {
                    Text("UTC").tag("UTC")
                    Text(L.tr("시스템", "System")).tag(TimeZone.current.identifier)
                }
                .pickerStyle(.menu)
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
                    TextField("", text: Binding(
                        get: { variable.name },
                        set: { newName in
                            if let idx = viewModel.dashboardConfig.templating.list.firstIndex(where: { $0.id == variable.id }) {
                                viewModel.dashboardConfig.templating.list[idx].name = newName
                                viewModel.saveDashboard()
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text(L.tr("라벨", "Label"))
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    TextField("", text: Binding(
                        get: { variable.label ?? "" },
                        set: { newLabel in
                            if let idx = viewModel.dashboardConfig.templating.list.firstIndex(where: { $0.id == variable.id }) {
                                viewModel.dashboardConfig.templating.list[idx].label = newLabel.isEmpty ? nil : newLabel
                                viewModel.saveDashboard()
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text(L.tr("값", "Values"))
                        .font(.caption)
                        .frame(width: 60, alignment: .leading)
                    TextField("", text: Binding(
                        get: { variable.query },
                        set: { newQuery in
                            if let idx = viewModel.dashboardConfig.templating.list.firstIndex(where: { $0.id == variable.id }) {
                                viewModel.dashboardConfig.templating.list[idx].query = newQuery
                                // Parse comma-separated values into options
                                viewModel.dashboardConfig.templating.list[idx].options = newQuery
                                    .split(separator: ",")
                                    .map { val in
                                        let trimmed = val.trimmingCharacters(in: .whitespaces)
                                        return VariableOption(text: trimmed, value: trimmed)
                                    }
                                viewModel.saveDashboard()
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
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
