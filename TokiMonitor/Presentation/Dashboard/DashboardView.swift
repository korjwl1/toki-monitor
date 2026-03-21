import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var showAddPanel = false
    @State private var showTimeRangePicker = false
    @State private var showDashboardList = false
    @State private var editingPanel: PanelConfig?

    init(reportClient: TokiReportClient) {
        _viewModel = State(initialValue: DashboardViewModel(reportClient: reportClient))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar bar (Grafana-style)
            dashboardToolbar

            // Variable bar (if variables exist)
            if !viewModel.variables.isEmpty {
                variableBar
            }

            // Main content
            Group {
                if viewModel.isLoading && viewModel.timeSeriesData == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    errorView(error)
                } else if viewModel.timeSeriesData != nil {
                    CustomDashboardView(viewModel: viewModel, onEditPanel: { panel in
                        editingPanel = panel
                    })
                } else {
                    emptyView
                }
            }
        }
        .onAppear { viewModel.fetchData() }
        .popover(isPresented: $showAddPanel) {
            AddPanelPopover(viewModel: viewModel)
        }
        .sheet(item: $editingPanel) { panel in
            PanelEditorView(panel: panel, viewModel: viewModel) { updated in
                viewModel.updatePanel(updated)
                editingPanel = nil
            }
        }
    }

    // MARK: - Dashboard Toolbar

    private var dashboardToolbar: some View {
        HStack(spacing: 8) {
            // Dashboard title / switcher
            dashboardTitle

            Spacer()

            // Model filter
            modelFilterMenu

            Divider().frame(height: 16)

            // Time range picker button
            timeRangeButton

            // Auto-refresh picker
            refreshPicker

            Divider().frame(height: 16)

            // Refresh now
            refreshButton

            Divider().frame(height: 16)

            // Edit mode controls
            editModeControls

            // Import/Export
            importExportMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Dashboard Title

    private var dashboardTitle: some View {
        HStack(spacing: 4) {
            if viewModel.isEditing {
                TextField(L.dash.title, text: Binding(
                    get: { viewModel.dashboardConfig.title },
                    set: { viewModel.dashboardConfig.title = $0; viewModel.saveDashboard() }
                ))
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 200)
            } else {
                Text(viewModel.dashboardConfig.title)
                    .font(.headline)
            }

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Time Range Button (Grafana-style dropdown)

    private var timeRangeButton: some View {
        Menu {
            // Quick ranges section
            Section(L.tr("빠른 범위", "Quick ranges")) {
                ForEach(TimeRangePreset.presets) { preset in
                    Button {
                        viewModel.setTimeRangePreset(preset)
                    } label: {
                        HStack {
                            Text(preset.label)
                            if viewModel.dashboardConfig.time.from == preset.from {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption)
                Text(viewModel.timeRangeLabel)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Auto-Refresh Picker

    private var refreshPicker: some View {
        Menu {
            ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                Button {
                    viewModel.refreshInterval = interval
                } label: {
                    HStack {
                        Text(interval.displayName)
                        if viewModel.refreshInterval == interval {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: viewModel.refreshInterval == .off
                    ? "arrow.clockwise"
                    : "arrow.clockwise.circle.fill"
                )
                .font(.caption)
                if viewModel.refreshInterval != .off {
                    Text(viewModel.refreshInterval.displayName)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Model Filter Menu

    private var modelFilterMenu: some View {
        Menu {
            Button(L.dash.selectAll) { viewModel.selectAllModels() }
            Button(L.dash.deselectAll) { viewModel.deselectAllModels() }
            Divider()
            if let data = viewModel.timeSeriesData {
                ForEach(data.allModelNames, id: \.self) { model in
                    Toggle(model, isOn: Binding(
                        get: { viewModel.enabledModels.contains(model) },
                        set: { _ in viewModel.toggleModel(model) }
                    ))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                Text(L.dash.filter)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button(action: { viewModel.fetchData() }) {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
    }

    // MARK: - Edit Mode Controls

    @ViewBuilder
    private var editModeControls: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.isEditing.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.isEditing ? "checkmark" : "pencil")
                    .font(.caption)
                Text(viewModel.isEditing ? L.dash.done : L.dash.edit)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                viewModel.isEditing
                    ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                    : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)

        if viewModel.isEditing {
            Button {
                showAddPanel = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                viewModel.resetToDefault()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Import/Export Menu

    private var importExportMenu: some View {
        Menu {
            Button {
                viewModel.exportDashboard()
            } label: {
                Label(L.tr("JSON 내보내기", "Export JSON"), systemImage: "square.and.arrow.up")
            }

            Button {
                viewModel.importDashboard()
            } label: {
                Label(L.tr("JSON 가져오기", "Import JSON"), systemImage: "square.and.arrow.down")
            }

            Divider()

            // Copy JSON to clipboard
            Button {
                if let json = try? viewModel.dashboardConfig.exportJSONString() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                }
            } label: {
                Label(L.tr("JSON 복사", "Copy JSON"), systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Variable Bar

    private var variableBar: some View {
        HStack(spacing: 12) {
            ForEach(viewModel.variables) { variable in
                if variable.hide != .hidden {
                    variableControl(for: variable)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar.opacity(0.5))
    }

    @ViewBuilder
    private func variableControl(for variable: DashboardVariable) -> some View {
        HStack(spacing: 4) {
            if variable.hide != .hideLabel, let label = variable.label ?? Optional(variable.name) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu {
                if variable.includeAll {
                    Button {
                        viewModel.updateVariable(id: variable.id, selection: VariableSelection(
                            text: ["All"], value: ["$__all"]
                        ))
                    } label: {
                        HStack {
                            Text("All")
                            if variable.current.value.contains("$__all") {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                }

                ForEach(variable.options, id: \.value) { option in
                    Button {
                        if variable.multi {
                            // Toggle multi-select
                            var current = variable.current
                            if current.value.contains(option.value) {
                                current.value.removeAll { $0 == option.value }
                                current.text.removeAll { $0 == option.text }
                            } else {
                                current.value.removeAll { $0 == "$__all" }
                                current.text.removeAll { $0 == "All" }
                                current.value.append(option.value)
                                current.text.append(option.text)
                            }
                            viewModel.updateVariable(id: variable.id, selection: current)
                        } else {
                            viewModel.updateVariable(id: variable.id, selection: VariableSelection(
                                text: [option.text], value: [option.value]
                            ))
                        }
                    } label: {
                        HStack {
                            Text(option.text)
                            if variable.current.value.contains(option.value) {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(variable.current.text.joined(separator: ", "))
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - States

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L.dash.error, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(L.account.retry) { viewModel.fetchData() }
                .buttonStyle(.bordered)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L.dash.loading,
            systemImage: "chart.xyaxis.line"
        )
    }
}
