import SwiftUI
import Charts

// Dashboard design system — mirrors MenuContentView DS (8pt grid)
private enum DS {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    static let fontTitle: CGFloat = 14
    static let fontBody: CGFloat = 12
    static let fontCaption: CGFloat = 10
    static let fontTiny: CGFloat = 9

    static let panelRadius: CGFloat = 14
    static let widgetRadius: CGFloat = 10
    static let btnRadius: CGFloat = 8
}

private let divClr = Color.primary.opacity(0.1)

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
        NavigationSplitView {
            dashboardSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
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
        .toolbar(removing: .sidebarToggle)
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
        List(selection: $sidebarSelection) {
            Section {
                Label(L.dash.dashboards, systemImage: "square.grid.2x2")
                    .tag(SidebarItem.dashboards)
                Label(L.dash.explore, systemImage: "magnifyingglass.circle")
                    .tag(SidebarItem.explore)
                Label(L.dash.playlists, systemImage: "play.rectangle")
                    .tag(SidebarItem.playlists)
                Label(L.dash.alerts, systemImage: "bell")
                    .tag(SidebarItem.alerts)
            }

            Section(L.dash.dashboards) {
                ForEach(viewModel.filteredDashboardList, id: \.uid) { dashboard in
                    Button {
                        viewModel.switchDashboard(dashboard)
                        sidebarSelection = .dashboards
                    } label: {
                        HStack(spacing: DS.sm) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: DS.fontTiny))
                                .foregroundStyle(.secondary)
                            Text(dashboard.title)
                                .font(.system(size: DS.fontBody))
                                .lineLimit(1)
                            Spacer()
                            if dashboard.uid == viewModel.dashboardConfig.uid {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }
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
            }
        }
        .safeAreaInset(edge: .top) {
            // Search field
            HStack(spacing: DS.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: DS.fontCaption))
                TextField(L.dash.search, text: $viewModel.sidebarSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.fontBody))
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)
        }
        .safeAreaInset(edge: .bottom) {
            // Bottom actions
            HStack(spacing: DS.sm) {
                Button {
                    viewModel.createNewDashboard()
                } label: {
                    Label(L.dash.newDashboard, systemImage: "plus")
                        .font(.system(size: DS.fontCaption))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    viewModel.importDashboard()
                    viewModel.dashboardList = viewModel.configStore.loadDashboardList()
                } label: {
                    Label(L.dash.importDashboard, systemImage: "square.and.arrow.down")
                        .font(.system(size: DS.fontCaption))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.md)
            .padding(.vertical, DS.sm)
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        VStack(spacing: 0) {
            // Top toolbar bar
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
        HStack(spacing: DS.md) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(Color.accentColor)
            Text(L.dash.playlists)
                .font(.system(size: DS.fontCaption))

            Spacer()

            Button {
                viewModel.playlistManager.previous { uid in
                    viewModel.switchDashboard(uid: uid)
                }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: DS.fontCaption))
            }
            .buttonStyle(.plain)

            Button {
                if viewModel.playlistManager.isPlaying {
                    viewModel.playlistManager.pause()
                }
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: DS.fontCaption))
            }
            .buttonStyle(.plain)

            Button {
                viewModel.playlistManager.next { uid in
                    viewModel.switchDashboard(uid: uid)
                }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: DS.fontCaption))
            }
            .buttonStyle(.plain)

            Button {
                viewModel.playlistManager.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: DS.fontCaption))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.xs)
        .background(Color.accentColor.opacity(0.1))
    }

    // MARK: - Dashboard Toolbar

    private var dashboardToolbar: some View {
        HStack(spacing: DS.sm) {
            // Dashboard title / switcher
            dashboardTitle

            Spacer()

            // Model filter
            modelFilterMenu

            toolbarDivider

            // Time range picker button
            timeRangeButton

            // Auto-refresh picker
            refreshPicker

            toolbarDivider

            // Refresh now
            refreshButton

            toolbarDivider

            // Edit mode controls
            editModeControls

            // More menu
            moreMenu
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(divClr).frame(height: 0.5)
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(divClr)
            .frame(width: 0.5, height: DS.lg)
    }

    // MARK: - Dashboard Title

    private var dashboardTitle: some View {
        HStack(spacing: DS.xs) {
            if viewModel.isEditing {
                TextField(L.dash.title, text: Binding(
                    get: { viewModel.dashboardConfig.title },
                    set: { viewModel.dashboardConfig.title = $0; viewModel.saveDashboard() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: DS.fontTitle, weight: .semibold))
                .frame(maxWidth: 200)
            } else {
                Text(viewModel.dashboardConfig.title)
                    .font(.system(size: DS.fontTitle, weight: .semibold))
            }

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            // Alert indicator
            if let state = overallAlertState, state == .alerting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: DS.fontCaption))
            }
        }
    }

    private var overallAlertState: AlertState? {
        let rules = viewModel.alertManager.allRules().filter(\.enabled)
        guard !rules.isEmpty else { return nil }
        if rules.contains(where: { $0.state == .alerting }) { return .alerting }
        return .ok
    }

    // MARK: - Time Range Button

    private var timeRangeButton: some View {
        Menu {
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
            HStack(spacing: DS.xs) {
                Image(systemName: "clock")
                    .font(.system(size: DS.fontCaption))
                Text(viewModel.timeRangeLabel)
                    .font(.system(size: DS.fontCaption))
                Image(systemName: "chevron.down")
                    .font(.system(size: DS.fontTiny))
            }
            .modifier(ToolbarPillModifier())
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
                .font(.system(size: DS.fontCaption))
                if viewModel.refreshInterval != .off {
                    Text(viewModel.refreshInterval.displayName)
                        .font(.system(size: DS.fontCaption))
                }
            }
            .modifier(ToolbarPillModifier())
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
            HStack(spacing: DS.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: DS.fontCaption))
                Text(L.dash.filter)
                    .font(.system(size: DS.fontCaption))
            }
            .modifier(ToolbarPillModifier())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button(action: { viewModel.fetchData() }) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: DS.fontCaption))
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
            HStack(spacing: DS.xs) {
                Image(systemName: viewModel.isEditing ? "checkmark" : "pencil")
                    .font(.system(size: DS.fontCaption))
                Text(viewModel.isEditing ? L.dash.done : L.dash.edit)
                    .font(.system(size: DS.fontCaption))
            }
            .modifier(ToolbarPillModifier(isActive: viewModel.isEditing))
        }
        .buttonStyle(.plain)

        if viewModel.isEditing {
            Button {
                showAddPanel = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: DS.fontCaption))
                    .modifier(ToolbarPillModifier())
            }
            .buttonStyle(.plain)

            // Add row button
            Button {
                viewModel.addRow()
            } label: {
                Image(systemName: "rectangle.split.1x2")
                    .font(.system(size: DS.fontCaption))
                    .modifier(ToolbarPillModifier())
            }
            .buttonStyle(.plain)
            .help(L.dash.addRow)

            Button {
                viewModel.resetToDefault()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: DS.fontCaption))
                    .modifier(ToolbarPillModifier())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - More Menu

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
                .font(.system(size: DS.fontCaption))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Variable Bar

    private var variableBar: some View {
        HStack(spacing: DS.md) {
            ForEach(viewModel.variables) { variable in
                if variable.hide != .hidden {
                    variableControl(for: variable)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DS.lg)
        .padding(.vertical, DS.sm)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(divClr).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func variableControl(for variable: DashboardVariable) -> some View {
        HStack(spacing: DS.xs) {
            if variable.hide != .hideLabel, let label = variable.label ?? Optional(variable.name) {
                Text(label)
                    .font(.system(size: DS.fontCaption))
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
                HStack(spacing: DS.xs) {
                    Text(variable.current.text.joined(separator: ", "))
                        .font(.system(size: DS.fontCaption))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: DS.fontTiny))
                }
                .modifier(ToolbarPillModifier())
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

// MARK: - Toolbar Pill Modifier (glass on macOS 26+, quaternary fallback)

private struct ToolbarPillModifier: ViewModifier {
    var isActive: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, DS.sm)
                .padding(.vertical, DS.xs)
                .glassEffect(.regular, in: .rect(cornerRadius: DS.btnRadius))
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: DS.btnRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    }
                }
        } else {
            content
                .padding(.horizontal, DS.sm)
                .padding(.vertical, DS.xs)
                .background(
                    isActive
                        ? AnyShapeStyle(Color.accentColor.opacity(0.2))
                        : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: DS.btnRadius, style: .continuous)
                )
        }
    }
}
