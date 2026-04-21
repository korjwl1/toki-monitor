import SwiftUI
import Charts


struct MenuContentView: View {
    let aggregator: TokenAggregator
    let connectionManager: ConnectionManager
    let usageMonitor: ClaudeUsageMonitor?
    let codexUsageMonitor: CodexUsageMonitor?
    let filterProviderId: String?
    @Bindable var settings: AppSettings

    var onStartDaemon: () -> Void
    var onOpenDashboard: () -> Void
    var onOpenSettings: (SettingsCategory?) -> Void
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
            switch connectionManager.state {
            case .connected:
                let items = orderedWidgetItems()
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.horizontal, DS.md) }
                    widgetView(for: item)
                }
            case .starting:
                startingWidget
            case .disconnected:
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

        // All widgets for enabled providers should show, regardless of data availability
        let enabledIds = Set(ProviderRegistry.configurableProviders
            .filter { settings.effectiveSettings(for: $0.id).enabled }
            .map(\.id))

        return order.filter { item in
            guard item.visible else { return false }
            if item.id == MenuWidgetItem.claudeUsageId {
                return enabledIds.contains("anthropic")
            }
            if item.id == MenuWidgetItem.codexUsageId {
                return enabledIds.contains("openai")
            }
            return enabledIds.contains(item.id)
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
                } else if !monitor.isAvailable {
                    claudeCodePrompt
                } else {
                    usageLoadingWidget(L.panel.claudeUsage, color: Color(red: 0.90, green: 0.50, blue: 0.25))
                }
            }
        } else if item.id == MenuWidgetItem.codexUsageId {
            if let monitor = codexUsageMonitor {
                if let usage = monitor.currentUsage {
                    codexUsageWidget(usage)
                } else if let err = monitor.lastError {
                    errorWidget(err)
                } else if !monitor.isAvailable {
                    codexLoginPrompt
                } else {
                    usageLoadingWidget(L.tr("Codex 사용량", "Codex Usage"), color: Color(red: 0.06, green: 0.64, blue: 0.50))
                }
            }
        } else {
            let summaries = buildDisplaySummaries()
            if let s = summaries.first(where: { $0.provider.id == item.id }) {
                providerWidget(s)
            }
        }
    }

    // MARK: - Login Prompts

    private var claudeCodePrompt: some View {
        HStack(spacing: DS.md) {
            Image(systemName: "terminal")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.90, green: 0.50, blue: 0.25))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.xs) {
                Text(L.panel.claudeUsage)
                    .font(.system(size: DS.fontTitle, weight: .semibold))
                Text(L.tr("Claude Code 로그인 필요", "Claude Code login required"))
                    .font(.system(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    private var codexLoginPrompt: some View {
        HStack(spacing: DS.md) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 14))
                .foregroundStyle(Color(red: 0.06, green: 0.64, blue: 0.50))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.xs) {
                Text(L.tr("Codex 사용량", "Codex Usage"))
                    .font(.system(size: DS.fontTitle, weight: .semibold))
                Text(L.tr("codex 앱을 열고 앱 내에서 로그인하세요", "Open Codex and sign in inside the app"))
                    .font(.system(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    private func usageLoadingWidget(_ title: String, color: Color) -> some View {
        HStack(spacing: DS.md) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: DS.fontTitle, weight: .semibold))
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
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
        let showFiveHour = settings.isClaudeUsageBucketVisible(.fiveHour)
        let showSevenDay = settings.isClaudeUsageBucketVisible(.sevenDay)
        let showSevenDaySonnet = settings.isClaudeUsageBucketVisible(.sevenDaySonnet)

        var rows: [(String, UsageBucket)] = []
        if showFiveHour, let fh = usage.fiveHour { rows.append((L.panel.fiveHour, fh)) }
        if showSevenDay, let sd = usage.sevenDay { rows.append((L.panel.sevenDay, sd)) }
        if showSevenDaySonnet, let sonnet = usage.sevenDaySonnet {
            rows.append((L.notification.claudeSevenDaySonnet, sonnet))
        }

        return HStack(spacing: DS.md) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(red: 0.90, green: 0.50, blue: 0.25))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: DS.sm) {
                Text(L.panel.claudeUsage)
                    .font(.system(size: DS.fontTitle, weight: .semibold))

                if rows.isEmpty {
                    Text(L.notification.noUsageBuckets)
                        .font(.system(size: DS.fontCaption))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        usageBar(row.0, row.1)
                    }
                }
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    private func usageBar(_ label: String, _ b: UsageBucket) -> some View {
        usageProgressBar(label: label, percent: b.utilization, countdown: b.resetCountdown)
    }

    // MARK: - Codex Usage Widget

    private func codexUsageWidget(_ usage: CodexUsageResponse) -> some View {
        let showPrimary = settings.isCodexUsageWindowVisible(.primary)
        let showSecondary = settings.isCodexUsageWindowVisible(.secondary)

        var rows: [(String, Int, String)] = []
        if showPrimary, let primary = usage.rateLimit.primaryWindow {
            rows.append((primary.windowLabel, primary.usedPercent, primary.resetCountdown))
        }
        if showSecondary, let secondary = usage.rateLimit.secondaryWindow {
            rows.append((secondary.windowLabel, secondary.usedPercent, secondary.resetCountdown))
        }

        return HStack(spacing: DS.md) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color(red: 0.06, green: 0.64, blue: 0.50))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: DS.sm) {
                Text(L.tr("Codex 사용량", "Codex Usage"))
                    .font(.system(size: DS.fontTitle, weight: .semibold))

                if rows.isEmpty {
                    Text(L.notification.noUsageBuckets)
                        .font(.system(size: DS.fontCaption))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        codexUsageBar(row.0, percent: row.1, countdown: row.2)
                    }
                }
            }
        }
        .padding(.leading, DS.sm)
        .padding(.trailing, DS.md)
        .padding(.vertical, DS.md)
    }

    private func codexUsageBar(_ label: String, percent: Int, countdown: String) -> some View {
        usageProgressBar(label: label, percent: Double(percent), countdown: countdown)
    }

    private func usageProgressBar(label: String, percent: Double, countdown: String) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            HStack {
                Text(label)
                    .font(.system(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: DS.fontCaption, weight: .semibold, design: .monospaced))
                Text("· \(countdown)")
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(percent >= 90 ? .red : percent >= 75 ? .orange : percent >= 50 ? .yellow : .green)
                        .frame(width: max(g.size.width * min(percent / 100, 1), 3))
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

    private var startingWidget: some View {
        VStack(spacing: DS.md) {
            ProgressView()
                .controlSize(.small)
            Text(L.tr("toki 데몬 시작 중...", "Starting toki daemon..."))
                .font(.system(size: DS.fontBody, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.xl)
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
            gridBtn(L.panel.settings, "gearshape") { onOpenSettings(nil) }
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
            syncStatusBtn
        }
        .padding(0)
    }

    // MARK: - Sync Status Button

    @ViewBuilder
    private var syncStatusBtn: some View {
        let syncManager = SyncManager.shared
        let (icon, color): (String, Color) = {
            guard syncManager.isConfigured else {
                return ("arrow.triangle.2.circlepath.circle", .secondary)
            }
            switch syncManager.liveStatus {
            case .connected:
                return ("arrow.triangle.2.circlepath", .green)
            case .disconnected:
                return ("arrow.triangle.2.circlepath", .orange)
            case .authFailed, .tokenExpired:
                return ("exclamationmark.arrow.triangle.2.circlepath", .red)
            case .unknown:
                return ("arrow.triangle.2.circlepath", .secondary)
            }
        }()
        Button { onOpenSettings(.sync) } label: {
            VStack(spacing: DS.xs) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(color)
                Text(L.sync.title)
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.secondary)
            }
            .frame(width: DS.Menu.btnSize, height: DS.Menu.btnSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                                .renderingMode(.template)
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
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
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
                .background(.ultraThinMaterial)
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
