import SwiftUI
import Charts

private let borderClr = Color.white.opacity(0.18)
private let subClr = Color.white.opacity(0.55)
private let dimClr = Color.white.opacity(0.3)

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
            leftPanel.frame(width: 200)
            rightPanel.frame(width: 80)
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Left

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isConnected {
                let summaries = buildDisplaySummaries()
                ForEach(Array(summaries.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { hDiv }
                    providerSection(s)
                }
                if let monitor = usageMonitor {
                    if let usage = monitor.currentUsage {
                        hDiv
                        usageSection(usage)
                    } else if let err = monitor.lastError {
                        hDiv
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(.system(size: 9))
                                .foregroundStyle(dimClr)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(dimClr)
                    Text("toki 미연결")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(subClr)
                    Button("데몬 시작", action: onStartDaemon)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private func providerSection(_ s: ProviderSummary) -> some View {
        let clr = s.provider.color(
            customColorName: settings.effectiveSettings(for: s.provider.id).customColorName
        )
        let hist = perProviderHistory[s.provider.id] ?? []
        let rate = aggregator.perProviderRates[s.provider.id] ?? 0

        return HStack(spacing: 10) {
            // Logo — vertically centered
            providerLogo(s.provider, color: clr)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                // Name + cost on one line
                HStack {
                    Text("\(s.provider.name):")
                        .font(.system(size: 13, weight: .bold))
                    if let c = s.estimatedCost, c > 0 {
                        Text(TokenFormatter.formatCost(c))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }

                HStack(spacing: 12) {
                    Label(TokenFormatter.formatRate(rate), systemImage: "speedometer")
                    let sessions = aggregator.perProviderSessionCount[s.provider.id] ?? 0
                    Label("\(sessions) 세션", systemImage: "person.2")
                }
                .font(.system(size: 10))
                .foregroundStyle(subClr)

                // Sparkline (always show — flat line if no data)
                spark(hist.count >= 2 ? hist : Array(repeating: 0, count: 30), color: clr)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func providerLogo(_ provider: ProviderInfo, color: Color) -> some View {
        if let logoName = provider.logoImage {
            Image(logoName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: provider.icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
        }
    }

    private func usageSection(_ usage: ClaudeUsageResponse) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 18))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text("Claude 사용량")
                    .font(.system(size: 13, weight: .bold))

                if let fh = usage.fiveHour { bar("5시간", fh) }
                if let sd = usage.sevenDay { bar("7일", sd) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func bar(_ label: String, _ b: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(subClr)
                Spacer()
                Text("\(Int(b.utilization))%").fontWeight(.medium)
                Text("· \(b.resetCountdown)")
                    .foregroundStyle(dimClr)
            }
            .font(.system(size: 10))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(b.utilization >= 90 ? .red : b.utilization >= 75 ? .orange : b.utilization >= 50 ? .yellow : .green)
                        .frame(width: max(g.size.width * min(b.utilization / 100, 1), 3))
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Right

    private var rightPanel: some View {
        VStack(spacing: 6) {
            gridBtn("대시보드", "chart.xyaxis.line", onOpenDashboard)
            gridBtn("설정", "gearshape", onOpenSettings)
            gridBtn(styleLabel, styleIcon) {
                switch settings.animationStyle {
                case .character: settings.animationStyle = .numeric
                case .numeric: settings.animationStyle = .sparkline
                case .sparkline: settings.animationStyle = .character
                }
            }
            Spacer(minLength: 0)
            gridBtn("종료", "power", onQuit)
        }
        .padding(6)
    }

    private func gridBtn(_ t: String, _ ic: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: ic)
                    .font(.system(size: 16))
                    .foregroundStyle(subClr)
                Text(t)
                    .font(.system(size: 9))
                    .foregroundStyle(dimClr)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderClr, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Components

    private func spark(_ h: [Double], color: Color) -> some View {
        let d = h.enumerated().map { (i: $0.offset, v: $0.element) }
        return Chart(d, id: \.i) { p in
            AreaMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(.linearGradient(
                    colors: [color.opacity(0.4), color.opacity(0)],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: 28)
    }

    private var hDiv: some View {
        Rectangle().fill(borderClr).frame(height: 0.5).padding(.horizontal, 12)
    }

    private var styleLabel: String {
        switch settings.animationStyle {
        case .character: "캐릭터"
        case .numeric: "수치"
        case .sparkline: "그래프"
        }
    }
    private var styleIcon: String {
        switch settings.animationStyle {
        case .character: "hare"
        case .numeric: "number"
        case .sparkline: "chart.line.uptrend.xyaxis"
        }
    }

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
