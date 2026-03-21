import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var showAddPanel = false
    @State private var showTimeRangePicker = false
    @State private var showDashboardList = false
    @State private var editingPanel: PanelConfig?
    @State private var showDashboardSettings = false
    @State private var showVersionHistory = false
    @State private var showAnnotationList = false
    @State private var sidebarSelection: SidebarItem? = .dashboards

    enum SidebarItem: Hashable {
        case dashboards
        case explore
        case playlists
        case alerts
    }

    init(reportClient: TokiReportClient) {
        _viewModel = State(initialValue: DashboardViewModel(reportClient: reportClient))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            if viewModel.showSidebar {
                dashboardSidebar
                    .frame(width: 220)
                    .transition(.move(edge: .leading))
            } else {
                // Thin strip to toggle sidebar back
                sidebarToggleStrip
            }

            Divider()

            // Main content area
            VStack(spacing: 0) {
                switch sidebarSelection {
                case .explore:
                    ExploreView(viewModel: viewModel)
                case .playlists:
                    PlaylistView(viewModel: viewModel)
                case .alerts:
                    AlertListView(viewModel: viewModel)
                default:
                    dashboardContent
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
        .sheet(isPresented: $showDashboardSettings) {
            DashboardSettingsSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showVersionHistory) {
            VersionHistorySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showAnnotationList) {
            AnnotationListSheet(viewModel: viewModel)
        }
    }

    // MARK: - Sidebar

    private var dashboardSidebar: some View {
        VStack(spacing: 0) {
            // Sidebar header
            HStack {
                Text(L.dash.dashboards)
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showSidebar = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(L.dash.search, text: $viewModel.sidebarSearchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))

            Divider()

            // Navigation items
            VStack(spacing: 2) {
                sidebarNavItem(
                    title: L.dash.dashboards,
                    icon: "square.grid.2x2",
                    item: .dashboards
                )
                sidebarNavItem(
                    title: L.dash.explore,
                    icon: "magnifyingglass.circle",
                    item: .explore
                )
                sidebarNavItem(
                    title: L.dash.playlists,
                    icon: "play.rectangle",
                    item: .playlists
                )
                sidebarNavItem(
                    title: L.dash.alerts,
                    icon: "bell",
                    item: .alerts
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Dashboard list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.filteredDashboardList, id: \.uid) { dashboard in
                        dashboardListItem(dashboard)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider()

            // Bottom actions
            HStack(spacing: 8) {
                Button {
                    viewModel.createNewDashboard()
                } label: {
                    Label(L.dash.newDashboard, systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.importDashboard()
                    viewModel.dashboardList = viewModel.configStore.loadDashboardList()
                } label: {
                    Label(L.dash.importDashboard, systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func sidebarNavItem(title: String, icon: String, item: SidebarItem) -> some View {
        Button {
            sidebarSelection = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                sidebarSelection == item
                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func dashboardListItem(_ dashboard: DashboardConfig) -> some View {
        Button {
            viewModel.switchDashboard(dashboard)
            sidebarSelection = .dashboards
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(dashboard.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if dashboard.uid == viewModel.dashboardConfig.uid {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                dashboard.uid == viewModel.dashboardConfig.uid
                    ? AnyShapeStyle(Color.accentColor.opacity(0.1))
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.duplicateDashboard(uid: dashboard.uid)
            } label: {
                Label(L.dash.duplicate, systemImage: "doc.on.doc")
            }
            Button {
                viewModel.configStore.exportToFile(dashboard)
            } label: {
                Label(L.tr("JSON 내보내기", "Export JSON"), systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                viewModel.deleteDashboard(uid: dashboard.uid)
            } label: {
                Label(L.dash.delete, systemImage: "trash")
            }
        }
    }

    private var sidebarToggleStrip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showSidebar = true
            }
        } label: {
            VStack {
                Spacer()
                Image(systemName: "sidebar.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(width: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            // Top toolbar bar (Grafana-style)
            dashboardToolbar

            // Variable bar (if variables exist)
            if !viewModel.variables.isEmpty {
                variableBar
            }

            // Playlist controls
            if viewModel.playlistManager.isPlaying {
                playlistControlBar
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
    }

    // MARK: - Playlist Control Bar

    private var playlistControlBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Color.accentColor)
            Text(L.dash.playlists)
                .font(.caption)

            Spacer()

            Button {
                viewModel.playlistManager.previous { uid in
                    viewModel.switchDashboard(uid: uid)
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Button {
                if viewModel.playlistManager.isPlaying {
                    viewModel.playlistManager.pause()
                }
            } label: {
                Image(systemName: "pause.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.playlistManager.next { uid in
                    viewModel.switchDashboard(uid: uid)
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.playlistManager.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1))
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

            // More menu (settings, versions, annotations, import/export)
            moreMenu
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

            // Alert indicator
            if let state = overallAlertState, state == .alerting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var overallAlertState: AlertState? {
        let rules = viewModel.alertManager.allRules().filter(\.enabled)
        guard !rules.isEmpty else { return nil }
        if rules.contains(where: { $0.state == .alerting }) { return .alerting }
        return .ok
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
                if !viewModel.isEditing {
                    viewModel.saveDashboardWithVersion()
                }
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

            // Add row button
            Button {
                viewModel.addRow()
            } label: {
                Image(systemName: "rectangle.split.1x2")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L.dash.addRow)

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

    // MARK: - More Menu (replaces import/export menu, adds settings/versions/annotations)

    private var moreMenu: some View {
        Menu {
            Button {
                showDashboardSettings = true
            } label: {
                Label(L.dash.dashboardSettings, systemImage: "gearshape")
            }

            Button {
                showVersionHistory = true
            } label: {
                Label(L.dash.versions, systemImage: "clock.arrow.circlepath")
            }

            Button {
                showAnnotationList = true
            } label: {
                Label(L.dash.annotations, systemImage: "note.text")
            }

            Divider()

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
