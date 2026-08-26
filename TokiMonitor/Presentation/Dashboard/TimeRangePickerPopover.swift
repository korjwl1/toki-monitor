import SwiftUI

/// Grafana-style time range picker with quick ranges + absolute time selection.
struct TimeRangePickerPopover: View {
    @Bindable var viewModel: DashboardViewModel
    @Binding var isPresented: Bool

    @State private var selectedTab: Tab = .quick
    @State private var absoluteFrom: Date = Date().addingTimeInterval(-86400)
    @State private var absoluteTo: Date = Date()

    enum Tab: String, CaseIterable {
        case quick, absolute

        var label: String {
            switch self {
            case .quick: L.tr("빠른 범위", "Quick ranges")
            case .absolute: L.tr("직접 선택", "Absolute")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker — always at top
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.rawValue) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Zoom and pan, in the one place a reader looks when they want to
            // change the range. The chords are owned by the dashboard's command
            // sink so that they work with this popover shut; naming them here
            // is how anyone finds out they exist (FR-062).
            navigationRow

            Divider()

            // Tab content — fills remaining space, top-aligned
            Group {
                switch selectedTab {
                case .quick:
                    quickRangesTab
                case .absolute:
                    absoluteTab
                }
            }
        }
        .frame(width: 280)
        .onAppear {
            let time = viewModel.dashboardConfig.time
            absoluteFrom = time.fromDate
            absoluteTo = time.toDate
        }
    }

    // MARK: - Zoom and pan

    private var navigationRow: some View {
        HStack(spacing: DS.xs) {
            navButton(.panBackward, symbol: "chevron.left") {
                viewModel.panTimeRange(by: -0.5)
            }
            navButton(.zoomOut, symbol: "minus.magnifyingglass") {
                viewModel.zoomTimeRange(2)
            }
            navButton(.zoomIn, symbol: "plus.magnifyingglass") {
                viewModel.zoomTimeRange(0.5)
            }
            navButton(.panForward, symbol: "chevron.right") {
                viewModel.panTimeRange(by: 0.5)
            }
            Spacer(minLength: 0)
            Text(viewModel.timeRangeLabel)
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(DS.bodySecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, DS.sm)
    }

    private func navButton(_ command: DashboardCommand, symbol: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(DS.iconSecondary)
                // 24x24 minimum hit area (FR-060), with the 4pt gaps around it
                // making up the 8pt separation between neighbours.
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .help("\(command.title) (\(command.chordDescription))")
        .accessibilityLabel(command.title)
    }

    // MARK: - Quick Ranges

    private var quickRangesTab: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(TimeRangePreset.presets, id: \.id) { preset in
                    quickRangeRow(preset)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(height: 320)
    }

    private func quickRangeRow(_ preset: TimeRangePreset) -> some View {
        let isSelected = viewModel.dashboardConfig.time.from == preset.from
        return Button {
            viewModel.setTimeRangePreset(preset)
            isPresented = false
        } label: {
            HStack {
                Text(preset.label)
                    .font(.system(size: 13))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    // MARK: - Absolute Time

    private var absoluteTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // From
            DatePicker(
                L.tr("시작", "From"),
                selection: $absoluteFrom,
                in: ...absoluteTo,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.system(size: 13))

            // To
            DatePicker(
                L.tr("종료", "To"),
                selection: $absoluteTo,
                in: absoluteFrom...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .font(.system(size: 13))

            // Duration
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.bodySecondary)
                Text(durationLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.bodySecondary)
            }

            // Apply
            Button {
                viewModel.setAbsoluteTimeRange(from: absoluteFrom, to: absoluteTo)
                isPresented = false
            } label: {
                Text(L.tr("적용", "Apply"))
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(16)
    }

    private var durationLabel: String {
        let interval = absoluteTo.timeIntervalSince(absoluteFrom)
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(minutes)" + L.tr("분", "m")
        }
        let hours = minutes / 60
        let remainMin = minutes % 60
        if hours < 24 {
            return remainMin == 0
                ? "\(hours)" + L.tr("시간", "h")
                : "\(hours)" + L.tr("시간", "h") + " \(remainMin)" + L.tr("분", "m")
        }
        let days = hours / 24
        let remainHours = hours % 24
        return remainHours == 0
            ? "\(days)" + L.tr("일", "d")
            : "\(days)" + L.tr("일", "d") + " \(remainHours)" + L.tr("시간", "h")
    }
}
