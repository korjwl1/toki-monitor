import SwiftUI
import Charts

struct MenuContentView: View {
    let aggregator: TokenAggregator
    let connectionManager: ConnectionManager
    let usageMonitor: ClaudeUsageMonitor?
    let filterProviderId: String?
    @Bindable var settings: AppSettings

    var onStartDaemon: () -> Void
    var onOpenDashboard: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var isConnected: Bool { connectionManager.state.isConnected }
    private var perProviderHistory: [String: [Double]] { aggregator.perProviderHistory }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftPanel.frame(width: 252)
            Divider()
            rightPanel.frame(width: 72)
        }
        .frame(minHeight: 200)
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Toki Monitor")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(isConnected ? "연결됨" : "미연결")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            sectionDivider

            if isConnected {
                // Provider sections
                let summaries = buildDisplaySummaries()
                ForEach(Array(summaries.enumerated()), id: \.element.id) { i, summary in
                    if i > 0 { sectionDivider }
                    providerSection(summary)
                }

                // Claude usage
                if let monitor = usageMonitor, let usage = monitor.currentUsage {
                    sectionDivider
                    claudeUsageSection(usage)
                }
            } else {
                disconnectedSection
            }
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            actionButton("대시보드", icon: "chart.xyaxis.line", action: onOpenDashboard)
            Divider().padding(.horizontal, 8)
            actionButton("설정", icon: "gearshape", action: onOpenSettings)
            Divider().padding(.horizontal, 8)
            actionButton(currentStyleLabel, icon: currentStyleIcon) {
                switch settings.animationStyle {
                case .character: settings.animationStyle = .numeric
                case .numeric: settings.animationStyle = .sparkline
                case .sparkline: settings.animationStyle = .character
                }
            }
            Spacer(minLength: 0)
            Divider().padding(.horizontal, 8)
            actionButton("종료", icon: "power", action: onQuit)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Provider Section

    private func providerSection(_ summary: ProviderSummary) -> some View {
        let effectiveColor = summary.provider.color(
            customColorName: settings.effectiveSettings(for: summary.provider.id).customColorName
        )
        let history = perProviderHistory[summary.provider.id] ?? []
        let rate = aggregator.perProviderRates[summary.provider.id] ?? 0

        return VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack(spacing: 6) {
                Image(systemName: summary.provider.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(effectiveColor)
                    .frame(width: 20)

                Text(summary.provider.name)
                    .font(.headline)

                Spacer()

                if let cost = summary.estimatedCost, cost > 0 {
                    Text(TokenFormatter.formatCost(cost))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                }
            }

            // Stats
            if summary.eventCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    statRow("Rate", TokenFormatter.formatRate(rate))
                    statRow("Input", TokenFormatter.formatTokens(summary.totalInput))
                    statRow("Output", TokenFormatter.formatTokens(summary.totalOutput))
                    statRow("호출", "\(summary.eventCount)")
                }
                .padding(.leading, 26)
            } else {
                Text("이벤트 없음")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            }

            // Sparkline
            if history.count >= 2 {
                sparkline(history, color: effectiveColor)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Claude Usage

    private func claudeUsageSection(_ usage: ClaudeUsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 16))
                    .foregroundStyle(.cyan)
                    .frame(width: 20)
                Text("Claude 사용량")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let fh = usage.fiveHour { usageBar("5시간 세션", bucket: fh) }
                if let sd = usage.sevenDay { usageBar("7일 주간", bucket: sd) }
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func usageBar(_ label: String, bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(bucket.utilization))%")
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(barColor(bucket.utilization))
                        .frame(width: geo.size.width * min(bucket.utilization / 100, 1))
                }
            }
            .frame(height: 5)

            Text("초기화: \(bucket.resetCountdown)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func barColor(_ pct: Double) -> Color {
        if pct >= 90 { .red }
        else if pct >= 75 { .orange }
        else if pct >= 50 { .yellow }
        else { .green }
    }

    // MARK: - Disconnected

    private var disconnectedSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("toki 데몬이 실행되지 않고 있습니다")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onStartDaemon) {
                Text("데몬 시작")
                    .font(.subheadline.weight(.medium))
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Components

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 12)
    }

    private func sparkline(_ history: [Double], color: Color) -> some View {
        let d = history.enumerated().map { (i: $0.offset, v: $0.element) }
        return Chart(d, id: \.i) { p in
            AreaMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(
                    .linearGradient(colors: [color.opacity(0.4), color.opacity(0)],
                                    startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: 24)
    }

    private var currentStyleLabel: String {
        switch settings.animationStyle {
        case .character: "캐릭터"
        case .numeric: "수치"
        case .sparkline: "그래프"
        }
    }
    private var currentStyleIcon: String {
        switch settings.animationStyle {
        case .character: "hare"
        case .numeric: "number"
        case .sparkline: "chart.line.uptrend.xyaxis"
        }
    }

    // MARK: - Data

    private func buildDisplaySummaries() -> [ProviderSummary] {
        let enabled = ProviderRegistry.configurableProviders.filter {
            settings.effectiveSettings(for: $0.id).enabled
        }
        if let fid = filterProviderId {
            if let e = aggregator.providerSummaries.first(where: { $0.provider.id == fid }) { return [e] }
            if let p = enabled.first(where: { $0.id == fid }) { return [ProviderSummary(provider: p)] }
            return []
        }
        return enabled.map { p in
            aggregator.providerSummaries.first(where: { $0.provider.id == p.id }) ?? ProviderSummary(provider: p)
        }
    }
}
