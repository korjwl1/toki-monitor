import SwiftUI

struct DashboardToolbar: View {
    @Bindable var viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("대시보드")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            // Time range buttons
            ForEach(DashboardTimeRange.allCases) { range in
                Button(range.displayName) {
                    viewModel.selectedTimeRange = range
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(viewModel.selectedTimeRange == range ? .accentColor : nil)
            }

            Divider().frame(height: 16)

            // Model filter
            Menu {
                Button("전체 선택") { viewModel.selectAllModels() }
                Button("전체 해제") { viewModel.deselectAllModels() }
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
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(action: { viewModel.fetchData() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
