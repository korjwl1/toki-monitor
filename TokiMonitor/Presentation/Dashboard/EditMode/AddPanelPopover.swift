import SwiftUI

/// Two-step popover for adding a new panel to the dashboard.
/// Step 1: Pick panel type. Step 2: Pick compatible metric.
struct AddPanelPopover: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: PanelType?
    @State private var selectedMetric: PanelMetric?

    var body: some View {
        VStack(spacing: 0) {
            if let panelType = selectedType {
                metricPicker(for: panelType)
            } else {
                typePicker
            }
        }
        .frame(width: 320, height: 340)
    }

    // MARK: - Step 1: Panel Type Picker

    private var typePicker: some View {
        VStack(spacing: 12) {
            Text(L.dash.pickPanelType)
                .font(.headline)
                .padding(.top, 16)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ],
                spacing: 12
            ) {
                ForEach(PanelType.creatableTypes, id: \.rawValue) { type in
                    Button {
                        selectedType = type
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: iconForType(type))
                                .font(.title2)
                                .frame(width: 40, height: 40)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            Text(type.displayName)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            Spacer()

            HStack {
                Button(L.dash.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Step 2: Metric Picker

    private func metricPicker(for panelType: PanelType) -> some View {
        let compatibleMetrics = PanelMetric.allCases.filter { metric in
            metric.compatiblePanelTypes.contains(panelType)
        }

        return VStack(spacing: 12) {
            HStack {
                Button {
                    selectedType = nil
                    selectedMetric = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(L.dash.pickMetric)
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            List(compatibleMetrics, id: \.rawValue) { metric in
                Button {
                    addPanel(type: panelType, metric: metric)
                } label: {
                    Label(metric.displayName, systemImage: metric.icon)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            HStack {
                Button(L.dash.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Add Panel

    private func addPanel(type: PanelType, metric: PanelMetric) {
        let position = DashboardGridLayout.firstAvailablePosition(
            width: type.minWidth,
            height: type.minHeight,
            existing: viewModel.dashboardConfig.panels
        )

        let panel = PanelConfig(
            title: metric.displayName,
            panelType: type,
            metric: metric,
            gridPosition: position
        )

        viewModel.addPanel(panel)
        dismiss()
    }

    // MARK: - Helpers

    private func iconForType(_ type: PanelType) -> String {
        type.icon
    }
}
