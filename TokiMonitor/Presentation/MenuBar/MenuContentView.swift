import SwiftUI
import Charts

/// The dropdown menu content shown when the status bar icon is clicked.
struct MenuContentView: View {
    let isConnected: Bool
    let tokensPerMinute: Double
    let providerSummaries: [ProviderSummary]
    let totalSummary: TotalSummary?
    let perProviderHistory: [String: [Double]]
    let filterProviderId: String?  // non-nil in per-provider mode
    @Bindable var settings: AppSettings

    var onStartDaemon: () -> Void
    var onOpenDashboard: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private let menuWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            divider

            if isConnected {
                connectedContent
            } else {
                disconnectedContent
            }

            divider
            styleSection
            divider
            footerSection
        }
        .frame(width: menuWidth)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Toki Monitor")
                        .font(.system(size: 13, weight: .semibold))
                    if let pid = filterProviderId,
                       let provider = ProviderRegistry.allProviders.first(where: { $0.id == pid }) {
                        Text(provider.name)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(provider.color.opacity(0.15))
                            .foregroundStyle(provider.color)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                HStack(spacing: 4) {
                    Text(isConnected
                         ? TokenFormatter.formatRate(tokensPerMinute)
                         : "미연결")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if isConnected {
                        Text("· \(settings.defaultTimeRange.displayName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(isConnected ? "연결됨" : "미연결")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Connected

    private var connectedContent: some View {
        VStack(spacing: 0) {
            let displaySummaries = buildDisplaySummaries()

            if displaySummaries.isEmpty {
                emptyState
            } else {
                // Total summary only in aggregated mode with 2+ providers
                if filterProviderId == nil, let total = totalSummary, displaySummaries.count >= 2 {
                    totalRow(total)
                    thinDivider
                }
                ForEach(displaySummaries) { summary in
                    providerRow(summary)
                }
            }
        }
    }

    /// Build summaries to display: include enabled providers even with 0 data.
    private func buildDisplaySummaries() -> [ProviderSummary] {
        let enabledProviders = ProviderRegistry.configurableProviders.filter {
            settings.effectiveSettings(for: $0.id).enabled
        }

        // If per-provider mode with filter, only show that provider
        if let filterId = filterProviderId {
            if let existing = providerSummaries.first(where: { $0.provider.id == filterId }) {
                return [existing]
            }
            if let provider = enabledProviders.first(where: { $0.id == filterId }) {
                return [ProviderSummary(provider: provider)]
            }
            return []
        }

        // Aggregated: show all enabled providers
        var result: [ProviderSummary] = []
        for provider in enabledProviders {
            if let existing = providerSummaries.first(where: { $0.provider.id == provider.id }) {
                result.append(existing)
            } else {
                result.append(ProviderSummary(provider: provider))
            }
        }
        return result
    }

    private var emptyState: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
            Text("이벤트 대기 중...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Provider Rows

    private func totalRow(_ total: TotalSummary) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .frame(width: 26, height: 26)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("전체")
                    .font(.system(size: 12, weight: .medium))
                Text("\(total.providerCount)개 프로바이더 · \(total.eventCount)회 호출")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            costLabel(total.estimatedCost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func providerRow(_ summary: ProviderSummary) -> some View {
        let effectiveColor = summary.provider.color(
            customColorName: settings.effectiveSettings(for: summary.provider.id).customColorName
        )
        let history = perProviderHistory[summary.provider.id] ?? []

        return VStack(spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(effectiveColor.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: summary.provider.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(effectiveColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.provider.name)
                        .font(.system(size: 12, weight: .medium))
                    if summary.eventCount > 0 {
                        HStack(spacing: 6) {
                            tokenBadge("↓", TokenFormatter.formatTokens(summary.totalInput))
                            tokenBadge("↑", TokenFormatter.formatTokens(summary.totalOutput))
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(.quaternary)
                            Text("\(summary.eventCount)회")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("이벤트 없음")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
                costLabel(summary.estimatedCost)
            }

            // Mini sparkline
            if history.count >= 2 {
                miniSparkline(history: history, color: effectiveColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func miniSparkline(history: [Double], color: Color) -> some View {
        let indexed = history.enumerated().map { (index: $0.offset, value: $0.element) }
        return Chart(indexed, id: \.index) { point in
            AreaMark(
                x: .value("t", point.index),
                y: .value("v", point.value)
            )
            .foregroundStyle(
                .linearGradient(
                    colors: [color.opacity(0.3), color.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("t", point.index),
                y: .value("v", point.value)
            )
            .foregroundStyle(color.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 30)
        .padding(.leading, 36)
    }

    private func tokenBadge(_ arrow: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(arrow)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func costLabel(_ cost: Double?) -> some View {
        Group {
            if let cost, cost > 0 {
                Text(TokenFormatter.formatCost(cost))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            } else {
                Text("--")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Disconnected

    private var disconnectedContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("toki 데몬이 실행되지 않고 있습니다")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(action: onStartDaemon) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("데몬 시작")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.blue.opacity(0.1))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Style Picker

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("메뉴바 스타일")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Picker("", selection: $settings.animationStyle) {
                Text("캐릭터").tag(AnimationStyle.character)
                Text("수치").tag(AnimationStyle.numeric)
                Text("그래프").tag(AnimationStyle.sparkline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.animationStyle == .character {
                Toggle(isOn: $settings.showRateText) {
                    Text("캐릭터 옆 토큰 수치 표시")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                if settings.showRateText {
                    inlinePicker("위치", selection: $settings.textPosition) {
                        Text("왼쪽").tag(TextPosition.leading)
                        Text("오른쪽").tag(TextPosition.trailing)
                    }
                }
            }

            if settings.animationStyle == .numeric ||
               (settings.animationStyle == .character && settings.showRateText) {
                inlinePicker("단위", selection: $settings.tokenUnit) {
                    ForEach(TokenUnit.allCases, id: \.self) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
            }

            inlinePicker("스파크라인 시간폭", selection: $settings.graphTimeRange) {
                ForEach(GraphTimeRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func inlinePicker<S: Hashable, C: View>(
        _ label: String,
        selection: Binding<S>,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Picker("", selection: selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 0) {
            menuButton("대시보드", icon: "chart.xyaxis.line", shortcut: "⌘D", action: onOpenDashboard)
            menuButton("설정...", icon: "gearshape", shortcut: "⌘,", action: onOpenSettings)
            thinDivider
            menuButton("종료", icon: "power", shortcut: "⌘Q", action: onQuit)
        }
    }

    private func menuButton(_ title: String, icon: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Dividers

    private var divider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.accentColor.opacity(0.15) : .clear)
                    .padding(.horizontal, 4)
            )
    }
}
