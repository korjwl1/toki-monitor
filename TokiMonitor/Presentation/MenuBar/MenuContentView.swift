import SwiftUI
import Charts

private let divClr = Color.primary.opacity(0.1)

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

    // Right button square size
    private let btnSize: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftPanel
                .frame(width: 210)
            rightPanel
                .frame(width: btnSize + 16)
        }
        .padding(.bottom, 8)
        .modifier(GlassPanelModifier())
    }

    // MARK: - Left

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConnected {
                let summaries = buildDisplaySummaries()
                ForEach(summaries) { s in
                    providerSection(s)
                }
                if let monitor = usageMonitor {
                    if let usage = monitor.currentUsage {
                        usageSection(usage)
                    } else if let err = monitor.lastError {
                        errorRow(err)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("toki 미연결")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("데몬 시작", action: onStartDaemon)
                        .font(.system(size: 11))
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            }
        }
        .padding(8)
    }

    private func providerSection(_ s: ProviderSummary) -> some View {
        let clr = s.provider.color(
            customColorName: settings.effectiveSettings(for: s.provider.id).customColorName
        )
        let hist = perProviderHistory[s.provider.id] ?? []
        let rate = aggregator.perProviderRates[s.provider.id] ?? 0
        let sessions = aggregator.perProviderSessionCount[s.provider.id] ?? 0

        return HStack(spacing: 12) {
            providerLogo(s.provider, color: clr)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.provider.name)
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if let c = s.estimatedCost, c > 0 {
                        Text(TokenFormatter.formatCost(c))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }

                HStack(spacing: 12) {
                    Label(TokenFormatter.formatRate(rate), systemImage: "speedometer")
                    Label("\(sessions) 세션", systemImage: "person.2")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                spark(hist.count >= 2 ? hist : Array(repeating: 0, count: 30), color: clr)
            }
        }
        .padding(12)
        .frame(minHeight: 100)
        .modifier(WidgetGlassModifier())
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

    // MARK: - Usage

    private func usageSection(_ usage: ClaudeUsageResponse) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 18))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                Text("Claude 사용량")
                    .font(.system(size: 13, weight: .bold))

                if let fh = usage.fiveHour { bar("5시간", fh) }
                if let sd = usage.sevenDay { bar("7일", sd) }
            }
        }
        .padding(12)
        .modifier(WidgetGlassModifier())
    }

    private func bar(_ label: String, _ b: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(b.utilization))%").fontWeight(.medium)
                Text("· \(b.resetCountdown)")
                    .foregroundStyle(.tertiary)
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

    private func errorRow(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(err)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(16)
    }

    // MARK: - Right

    private var rightPanel: some View {
        VStack(spacing: 8) {
            gridBtn("대시보드", "chart.xyaxis.line", onOpenDashboard)
            gridBtn("설정", "gearshape", onOpenSettings)
            gridBtn(styleLabel, styleIcon) {
                switch settings.animationStyle {
                case .character: settings.animationStyle = .numeric
                case .numeric: settings.animationStyle = .sparkline
                case .sparkline: settings.animationStyle = .character
                }
            }
        }
        .padding(8)
        .modifier(GlassContainerModifier())
    }

    private func gridBtn(_ t: String, _ ic: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: ic)
                    .font(.system(size: 18, weight: .light))
                Text(t)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: btnSize, height: btnSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(GlassButtonModifier())
    }

    // MARK: - Components

    private func spark(_ h: [Double], color: Color) -> some View {
        let d = h.enumerated().map { (i: $0.offset, v: $0.element) }
        let yMax = max(h.max() ?? 1, 1)  // never 0 — prevents auto-range padding
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
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: 28)
    }

    private var hDiv: some View {
        Divider().padding(.horizontal, 16)
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

    // MARK: - Build Data

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

// MARK: - Glass Panel (whole panel as liquid glass)

private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
        }
    }
}

private struct WidgetGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Glass Modifiers

private struct GlassContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
            }
        } else {
            content
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
    }
}
