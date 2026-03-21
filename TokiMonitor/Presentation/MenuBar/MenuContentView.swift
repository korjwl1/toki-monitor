import SwiftUI
import Charts

// Design system based on 8pt grid + golden ratio
private enum DS {
    // Spacing (8pt grid)
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    // Typography (modular scale 1.125 — compact UI)
    static let fontTitle: CGFloat = 14
    static let fontBody: CGFloat = 12
    static let fontCaption: CGFloat = 10
    static let fontTiny: CGFloat = 9

    // Layout
    static let leftWidth: CGFloat = 200
    static let rightWidth: CGFloat = 56
    static let btnSize: CGFloat = 56      // square buttons

    // Border radius (nested: inner = outer - padding)
    static let panelRadius: CGFloat = 14
    static let widgetRadius: CGFloat = 10  // 14 - 4(gap)
    static let btnRadius: CGFloat = 8

    // Chart
    static let chartHeight: CGFloat = 32
}

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

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftPanel.frame(width: DS.leftWidth)
            rightPanel.frame(width: DS.rightWidth)
        }
        .padding(DS.sm)
        .modifier(GlassPanelModifier())
        .ignoresSafeArea()
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if isConnected {
                let summaries = buildDisplaySummaries()
                ForEach(Array(summaries.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().padding(.horizontal, DS.md) }
                    providerWidget(s)
                }
                if let monitor = usageMonitor {
                    if let usage = monitor.currentUsage {
                        Divider().padding(.horizontal, DS.md)
                        usageWidget(usage)
                    } else if let err = monitor.lastError {
                        errorWidget(err)
                    }
                }
            } else {
                disconnectedWidget
            }
        }
        .padding(0)
    }

    // MARK: - Provider Widget

    private func providerWidget(_ s: ProviderSummary) -> some View {
        let clr = s.provider.color(
            customColorName: settings.effectiveSettings(for: s.provider.id).customColorName
        )
        let hist = perProviderHistory[s.provider.id] ?? []
        let rate = aggregator.perProviderRates[s.provider.id] ?? 0
        let sessions = aggregator.perProviderSessionCount[s.provider.id] ?? 0

        return HStack(spacing: DS.md) {
            // Icon — vertically centered
            providerLogo(s.provider, color: clr)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.xs) {
                // Name + cost
                HStack {
                    Text(s.provider.name)
                        .font(.system(size: DS.fontTitle, weight: .semibold))
                    Spacer()
                    if let c = s.estimatedCost, c > 0 {
                        Text(TokenFormatter.formatCost(c))
                            .font(.system(size: DS.fontTitle, weight: .semibold, design: .monospaced))
                    }
                }

                // Metrics
                HStack(spacing: DS.md) {
                    Label(TokenFormatter.formatRate(rate), systemImage: "speedometer")
                    Label("\(sessions) 세션", systemImage: "person.2")
                }
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(.secondary)

                // Sparkline
                sparkline(hist.count >= 2 ? hist : Array(repeating: 0, count: 30), color: clr)
                    .padding(.top, DS.xs)
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    @ViewBuilder
    private func providerLogo(_ provider: ProviderInfo, color: Color) -> some View {
        if let logoName = provider.logoImage {
            Image(logoName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(Circle())
        } else {
            Image(systemName: provider.icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
        }
    }

    // MARK: - Usage Widget

    private func usageWidget(_ usage: ClaudeUsageResponse) -> some View {
        HStack(spacing: DS.md) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.cyan)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: DS.sm) {
                Text("Claude 사용량")
                    .font(.system(size: DS.fontTitle, weight: .semibold))

                if let fh = usage.fiveHour { usageBar("5시간", fh) }
                if let sd = usage.sevenDay {
                    usageBar("7일", sd)
                }
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    private func usageBar(_ label: String, _ b: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                Text(label)
                    .font(.system(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(b.utilization))%")
                    .font(.system(size: DS.fontCaption, weight: .semibold, design: .monospaced))
                Text("· \(b.resetCountdown)")
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(b.utilization >= 90 ? .red : b.utilization >= 75 ? .orange : b.utilization >= 50 ? .yellow : .green)
                        .frame(width: max(g.size.width * min(b.utilization / 100, 1), 3))
                }
            }
            .frame(height: 4)
        }
    }

    private func errorWidget(_ err: String) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(err)
                .font(.system(size: DS.fontTiny))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(DS.md)
    }

    private var disconnectedWidget: some View {
        VStack(spacing: DS.md) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("toki 미연결")
                .font(.system(size: DS.fontBody, weight: .medium))
                .foregroundStyle(.secondary)
            Button("데몬 시작", action: onStartDaemon)
                .font(.system(size: DS.fontCaption))
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.xl)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: DS.sm) {
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
        .padding(0)
    }

    private func gridBtn(_ t: String, _ ic: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.xs) {
                Image(systemName: ic)
                    .font(.system(size: 18, weight: .light))
                Text(t)
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.secondary)
            }
            .frame(width: DS.btnSize, height: DS.btnSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sparkline

    private func sparkline(_ h: [Double], color: Color) -> some View {
        let d = h.enumerated().map { (i: $0.offset, v: $0.element) }
        let yMax = max(h.max() ?? 1, 1)
        return Chart(d, id: \.i) { p in
            AreaMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(.linearGradient(
                    colors: [color.opacity(0.35), color.opacity(0)],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("", p.i), y: .value("", p.v))
                .foregroundStyle(color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: 0...yMax)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .frame(height: DS.chartHeight)
    }

    // MARK: - Helpers

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

// MARK: - Glass Modifiers

private struct GlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: DS.panelRadius))
        } else {
            content
        }
    }
}

private struct WidgetGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: DS.widgetRadius))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.widgetRadius, style: .continuous))
        }
    }
}

private struct GlassContainerModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

private struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: DS.btnRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.btnRadius, style: .continuous))
        }
    }
}
