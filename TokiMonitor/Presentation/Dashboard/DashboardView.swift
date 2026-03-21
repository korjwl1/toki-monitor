import SwiftUI
import Charts

struct DashboardView: View {
    @State private var viewModel: DashboardViewModel
    @State private var showAddPanel = false

    init(reportClient: TokiReportClient) {
        _viewModel = State(initialValue: DashboardViewModel(reportClient: reportClient))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.timeSeriesData == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.timeSeriesData != nil {
                CustomDashboardView(viewModel: viewModel)
            } else {
                emptyView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                timeRangePicker
                Spacer()
                editModeControls
                modelFilterMenu
                refreshButton
            }
        }
        .navigationTitle(L.dash.title)
        .onAppear { viewModel.fetchData() }
        .popover(isPresented: $showAddPanel) {
            AddPanelPopover(viewModel: viewModel)
        }
    }

    // MARK: - Toolbar Items

    private var timeRangePicker: some View {
        Picker(L.dash.period, selection: $viewModel.selectedTimeRange) {
            ForEach(DashboardTimeRange.allCases) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 400)
    }

    @ViewBuilder
    private var editModeControls: some View {
        // Edit / Done toggle
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.isEditing.toggle()
            }
        } label: {
            Label(
                viewModel.isEditing ? L.dash.done : L.dash.edit,
                systemImage: viewModel.isEditing ? "checkmark" : "pencil"
            )
        }

        // Add panel (edit mode only)
        if viewModel.isEditing {
            Button {
                showAddPanel = true
            } label: {
                Label(L.dash.addPanel, systemImage: "plus")
            }

            Button {
                viewModel.resetToDefault()
            } label: {
                Label(L.dash.resetLayout, systemImage: "arrow.counterclockwise")
            }
        }
    }

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
            Label(L.dash.filter, systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var refreshButton: some View {
        Button(action: { viewModel.fetchData() }) {
            Label(L.dash.refresh, systemImage: "arrow.clockwise")
        }
        .disabled(viewModel.isLoading)
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
