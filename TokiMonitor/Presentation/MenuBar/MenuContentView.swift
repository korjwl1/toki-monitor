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
            leftPanel.frame(width: DS.Menu.leftWidth)
            rightPanel.frame(width: DS.Menu.rightWidth)
        }
        .padding(DS.sm)
        .modifier(GlassPanelModifier())
        .ignoresSafeArea()
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            if isConnected {
                let items = orderedWidgetItems()
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.horizontal, DS.md) }
                    widgetView(for: item)
                }
            } else {
                disconnectedWidget
            }
        }
        .padding(0)
    }

    private func orderedWidgetItems() -> [MenuWidgetItem] {
        let order: [MenuWidgetItem]
        if let pid = filterProviderId {
            order = settings.resolvedProviderWidgetOrder(for: pid)
        } else {
            order = settings.resolvedWidgetOrder()
        }

        let summaries = buildDisplaySummaries()
        let summaryIds = Set(summaries.map(\.provider.id))

        return order.filter { item in
            guard item.visible else { return false }
            if item.id == MenuWidgetItem.claudeUsageId {
                return usageMonitor?.currentUsage != nil || usageMonitor?.lastError != nil
            }
            return summaryIds.contains(item.id)
        }
    }

    @ViewBuilder
    private func widgetView(for item: MenuWidgetItem) -> some View {
        if item.id == MenuWidgetItem.claudeUsageId {
            if let monitor = usageMonitor {
                if let usage = monitor.currentUsage {
                    usageWidget(usage)
                } else if let err = monitor.lastError {
                    errorWidget(err)
                }
            }
        } else {
            let summaries = buildDisplaySummaries()
            if let s = summaries.first(where: { $0.provider.id == item.id }) {
                providerWidget(s)
            }
        }
    }

    // MARK: - Provider Widget

    private func providerWidget(_ s: ProviderSummary) -> some View {
        let clr = s.provider.color(
            customColorName: settings.effectiveSettings(for: s.provider.id).customColorName
        )
        let hist = perProviderHistory[s.provider.id] ?? []
        let rate = aggregator.perProviderRates[s.provider.id] ?? 0
        let sessions = aggregator.perProviderSessionCount[s.provider.id] ?? 0
        let cpm = aggregator.perProviderCostPerMinute[s.provider.id] ?? 0

        return HStack(spacing: DS.md) {
            providerLogo(s.provider, color: clr)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.xs) {
                HStack {
                    Text(s.provider.name)
                        .font(.system(size: DS.fontTitle, weight: .semibold))
                    Spacer()
                    Text(TokenFormatter.formatCost(cpm) + "/m")
                        .font(.system(size: DS.fontTitle, weight: .semibold, design: .monospaced))
                }

                // Metrics
                HStack(spacing: DS.md) {
                    Label(TokenFormatter.formatRate(rate), systemImage: "speedometer")
                    Label(L.panel.sessions(sessions), systemImage: "person.2")
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
                Text(L.panel.claudeUsage)
                    .font(.system(size: DS.fontTitle, weight: .semibold))

                if let fh = usage.fiveHour { usageBar(L.panel.fiveHour, fh) }
                if let sd = usage.sevenDay {
                    usageBar(L.panel.sevenDay, sd)
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
            Text(L.panel.disconnected)
                .font(.system(size: DS.fontBody, weight: .medium))
                .foregroundStyle(.secondary)
            Button(L.panel.startDaemon, action: onStartDaemon)
                .font(.system(size: DS.fontCaption))
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.xl)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: DS.sm) {
            gridBtn(L.panel.dashboard, "chart.xyaxis.line", onOpenDashboard)
            gridBtn(L.panel.settings, "gearshape", onOpenSettings)
            styleToggleBtn {
                if let pid = filterProviderId {
                    // Per-provider: cycle this provider's style override
                    var ps = settings.effectiveSettings(for: pid)
                    let current = ps.animationStyle ?? settings.animationStyle
                    let next: AnimationStyle = switch current {
                    case .character: .numeric
                    case .numeric: .sparkline
                    case .sparkline: .character
                    }
                    ps.animationStyle = next
                    settings.providerSettingsMap[pid] = ps
                } else {
                    // Aggregated: cycle global style
                    switch settings.animationStyle {
                    case .character: settings.animationStyle = .numeric
                    case .numeric: settings.animationStyle = .sparkline
                    case .sparkline: settings.animationStyle = .character
                    }
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
            .frame(width: DS.Menu.btnSize, height: DS.Menu.btnSize)
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
        .frame(height: DS.Menu.chartHeight)
    }

    // MARK: - Helpers

    private var currentStyle: AnimationStyle {
        if let pid = filterProviderId {
            return settings.effectiveSettings(for: pid).animationStyle ?? settings.animationStyle
        }
        return settings.animationStyle
    }

    private func styleToggleBtn(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.xs) {
                Group {
                    switch currentStyle {
                    case .character:
                        if let url = Bundle.main.url(forResource: "frame_00_thin", withExtension: "png"),
                           let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 24)
                        } else {
                            Image(systemName: "figure.run")
                                .font(.system(size: 18, weight: .light))
                        }
                    case .numeric:
                        Image(systemName: "number")
                            .font(.system(size: 18, weight: .light))
                    case .sparkline:
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 18, weight: .light))
                    }
                }
                .frame(height: 20)
                Text(styleLabel)
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.secondary)
            }
            .frame(width: DS.Menu.btnSize, height: DS.Menu.btnSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var styleLabel: String {
        switch currentStyle {
        case .character: L.menuBar.character
        case .numeric: L.menuBar.numeric
        case .sparkline: L.menuBar.graph
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
