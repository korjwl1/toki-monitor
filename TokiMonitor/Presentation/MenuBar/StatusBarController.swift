import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let connectionManager: ConnectionManager
    private let eventStream: TokiEventStream
    private let aggregator = TokenAggregator()

    // Status item units (single for aggregated, multiple for perProvider)
    private var units: [StatusItemUnit] = []
    private var lastSpendAlerts: [String: TokenAggregator.SpendAlert] = [:]
    private var currentUnitAlerts: [String: TokenAggregator.SpendAlert] = [:]
    private var hitEffectTimer: Timer?
    private let aggregatedAlertKey = "aggregated"

    // Dashboard & Settings
    private let dashboardController = DashboardWindowController()
    let settings: AppSettings = {
        let s = AppSettings()
        L.settings = s
        return s
    }()
    private lazy var settingsController = SettingsWindowController(settings: settings)

    // Claude Usage (reads auth from Claude Code's Keychain)
    private lazy var usageMonitor = ClaudeUsageMonitor(
        aggregator: aggregator,
        settings: settings
    )

    // Codex Usage
    private lazy var codexUsageMonitor = CodexUsageMonitor(
        aggregator: aggregator,
        settings: settings
    )

    // Update Checker
    private let updateChecker = UpdateChecker()
    // Version Compatibility
    private let versionChecker = VersionCompatibilityChecker()
    /// Codex root가 resolve된 이후에만 polling을 시작해야 하므로 플래그로 추적
    private var codexRootResolved = false

    // Menu panel
    private var menuPanel: NSPanel?
    private var menuHostingView: NSHostingView<MenuContentView>?
    private var panelRefreshTimer: Timer?
    private var eventMonitor: Any?
    private var globalMonitor: Any?
    private var sleepObserver: Any?
    private var wakeObserver: Any?
    private var lastPanelUnit: StatusItemUnit?

    init() {
        eventStream = TokiEventStream()
        connectionManager = ConnectionManager(eventStream: eventStream)

        setupEventHandling()
        setupSleepWakeHandling()

        // Apply settings
        aggregator.settings = settings
        aggregator.timeRange = settings.defaultTimeRange
        aggregator.graphTimeRange = settings.graphTimeRange
        aggregator.startSampling()
        if isClaudeWidgetVisible { usageMonitor.startPolling() }

        // Startup sequence: daemon → settings sync → codex root → connect
        Task {
            // Ensure daemon is running (start if not)
            if !(await connectionManager.isDaemonRunningPublic()) {
                connectionManager.startDaemonAndConnect()
                // Wait for daemon to be ready
                for _ in 0..<5 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if await connectionManager.isDaemonRunningPublic() { break }
                }
            } else {
                connectionManager.checkAndConnect()
            }
            await syncProvidersOnFirstLaunch()
            await CodexAuthReader.resolveCodexRoot()
            codexRootResolved = true
            if isCodexWidgetVisible { codexUsageMonitor.startPolling() }
            updateChecker.checkOnLaunch()
            versionChecker.checkOnLaunch()
            // Rebuild after sync so status items reflect actual provider state
            rebuildStatusItems()
        }

        // Build initial status items (will be rebuilt after sync completes)
        rebuildStatusItems()

        // Observe
        observeTokenRate()
        observeSettings()
        observeTokenActivity()
    }

    // MARK: - First Launch & Daemon

    private static let hasLaunchedKey = "hasLaunchedBefore"

    private func syncProvidersOnFirstLaunch() async {
        guard !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)

        // Read providers from toki settings
        do {
            let data = try await CLIProcessRunner.run(
                executable: TokiPath.resolved,
                arguments: ["settings", "get", "providers"]
            )
            let output = String(data: data, encoding: .utf8) ?? ""
            // Parse table format: lines with "[enabled]" contain provider IDs in first column
            let tokiProviders = output.components(separatedBy: "\n")
                .filter { $0.contains("[enabled]") }
                .compactMap { line -> String? in
                    let id = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces).first
                    return id?.isEmpty == false ? id : nil
                }

            // Map toki provider IDs to app provider IDs and enable only those
            let allProviders = ProviderRegistry.configurableProviders
            for provider in allProviders {
                let isInToki = provider.schemas.contains { tokiProviders.contains($0) }
                settings.setProviderEnabled(provider.id, enabled: isInToki, tokiProviderId: provider.tokiProviderId)
            }
            rebuildStatusItems()
        } catch {
            // toki not available — keep defaults (all enabled)
        }
    }

    // StatusBarController lives for app lifetime — no deinit cleanup needed.

    // MARK: - Setup

    private func setupEventHandling() {
        eventStream.onEvent = { [weak self] event in
            self?.aggregator.addEvent(event)
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeHandling() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                for unit in self?.units ?? [] {
                    unit.statusItem.button?.title = ""
                }
                self?.aggregator.stopSampling()
            }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.aggregator.startSampling()
                self?.updateAllDisplays()
            }
        }
    }

    // MARK: - Status Item Management

    private func rebuildStatusItems() {
        // Tear down existing
        for unit in units {
            unit.teardown()
        }
        units.removeAll()

        switch settings.providerDisplayMode {
        case .aggregated:
            let unit = StatusItemUnit(providerId: nil)
            unit.onClick = { [weak self] in self?.handleClick(from: unit) }
            unit.onRightClick = { [weak self] in self?.showContextMenu(from: unit) }
            units.append(unit)

        case .perProvider:
            let providers = ProviderRegistry.configurableProviders.filter { provider in
                settings.effectiveSettings(for: provider.id).enabled
            }
            for provider in providers {
                let unit = StatusItemUnit(providerId: provider.id)
                unit.onClick = { [weak self] in self?.handleClick(from: unit) }
                unit.onRightClick = { [weak self] in self?.showContextMenu(from: unit) }
                units.append(unit)
            }
            // Fallback: at least one unit
            if units.isEmpty {
                let unit = StatusItemUnit(providerId: nil)
                unit.onClick = { [weak self] in self?.handleClick(from: unit) }
                unit.onRightClick = { [weak self] in self?.showContextMenu(from: unit) }
                units.append(unit)
            }
        }

        updateAllDisplays()
    }

    private func updateAllDisplays() {
        applyAlertEffects()

        for unit in units {
            if let pid = unit.providerId {
                let rate = aggregator.perProviderRates[pid] ?? 0
                let history = aggregator.perProviderHistory[pid] ?? []
                let style = settings.effectiveStyle(for: pid)
                let colorName = settings.effectiveColorName(
                    for: ProviderRegistry.allProviders.first { $0.id == pid } ?? ProviderRegistry.unknown
                )
                let tint = ProviderInfo.nsColorFromName(colorName)
                let ps = settings.effectiveSettings(for: pid)
                let effectiveHPSource: HPBarSource = {
                    if let explicit = ps.hpBarSource { return explicit }
                    // Fallback to global only if it matches this provider
                    let global = settings.hpBarSource
                    if global.providerId == pid { return global }
                    return .none
                }()
                let perProviderHP = resolveHPBar(source: effectiveHPSource)
                unit.update(
                    tokensPerMinute: rate,
                    history: history,
                    style: style,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint,
                    sleepDelay: settings.sleepDelay.interval,
                    themeId: settings.animationThemeId,
                    hpBarValue: perProviderHP
                )
            } else {
                let baseTint: NSColor? = settings.aggregatedColorName.map { ProviderInfo.nsColorFromName($0) }
                let tint = baseTint
                let aggregatedHP = resolveHPBar(source: settings.hpBarSource)
                unit.update(
                    tokensPerMinute: aggregator.tokensPerMinute,
                    history: aggregator.recentHistory,
                    style: settings.animationStyle,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint,
                    sleepDelay: settings.sleepDelay.interval,
                    themeId: settings.animationThemeId,
                    hpBarValue: aggregatedHP
                )
            }
        }
    }

    // MARK: - Right Click → Context Menu

    private func showContextMenu(from unit: StatusItemUnit) {
        dismissPanel()
        let menu = NSMenu()
        menu.addItem(withTitle: L.panel.settings, action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.tr("종료", "Quit"), action: #selector(quitApp), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        unit.statusItem.menu = menu
        unit.statusItem.button?.performClick(nil)
        // Remove menu after showing so left-click works normally
        DispatchQueue.main.async { unit.statusItem.menu = nil }
    }

    @objc private func openSettingsFromMenu() {
        settingsController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Click → Panel

    private func handleClick(from unit: StatusItemUnit) {
        if menuPanel != nil {
            dismissPanel()
            return
        }

        let contentView = MenuContentView(
            aggregator: aggregator,
            connectionManager: connectionManager,
            usageMonitor: usageMonitor,
            codexUsageMonitor: codexUsageMonitor,
            filterProviderId: unit.providerId,
            settings: settings,
            onStartDaemon: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async {
                    self?.connectionManager.startDaemonAndConnect()
                }
            },
            onOpenDashboard: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async {
                    self?.dashboardController.show()
                }
            },
            onOpenSettings: { [weak self] category in
                self?.dismissPanel()
                DispatchQueue.main.async {
                    self?.settingsController.show(category: category)
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize]
        if #available(macOS 14.0, *) {
            hostingView.safeAreaRegions = []
        }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.setFrameSize(resolvedContentSize(for: hostingView))
        menuHostingView = hostingView

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        // Cosmetically borderless — hide titlebar chrome
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isMovable = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true

        panel.contentView = hostingView
        // Trigger layout now that the hosting view is mounted in a window —
        // guarantees panel.frame.size reflects real SwiftUI content before we
        // compute the origin.
        panel.layoutIfNeeded()

        // Position below the clicked status item
        if let button = unit.statusItem.button,
           let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

            // Identify the screen the user clicked on. The cursor position at
            // click time is more reliable than button.window.screen, which can
            // resolve to the primary display on multi-display setups.
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? buttonWindow.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(buttonFrame.origin) })
                ?? NSScreen.main
            let screenFrame = screen?.visibleFrame ?? .zero

            // NSHostingView.fittingSize can return (0, 0) on the first click
            // before SwiftUI has resolved layout. A zero-sized panel inflates
            // upward from its bottom-left origin once real content renders,
            // pushing the visible panel off-screen (or onto an adjacent display
            // on vertically stacked multi-monitor setups).
            panel.setContentSize(resolvedContentSize(for: hostingView))
            let panelSize = panel.frame.size

            var x = buttonFrame.minX
            if !(screenFrame.minX...screenFrame.maxX).contains(x) {
                x = mouseLocation.x - panelSize.width / 2
            }
            if x + panelSize.width > screenFrame.maxX {
                x = screenFrame.maxX - panelSize.width - 4
            }
            if x < screenFrame.minX {
                x = screenFrame.minX + 4
            }

            // Anchor below the menu bar of the clicked screen. Using
            // screenFrame.maxY rather than buttonFrame.minY keeps the panel on
            // the intended display even if buttonFrame reflects another screen's
            // coordinates.
            let y = screenFrame.maxY - panelSize.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        menuPanel = panel
        lastPanelUnit = unit

        // Observation-driven refresh: update rootView only when data actually changes
        scheduleObservationRefresh(for: unit)

        // Safety-net fallback timer at low frequency
        panelRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPanelContent(for: unit)
            }
        }

        // Dismiss when clicking outside (but not on any of our status bar buttons)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let panel = self.menuPanel else { return event }
            let clickPoint = NSEvent.mouseLocation

            // Ignore clicks on any of our status bar buttons
            for u in self.units {
                if let frame = self.statusItemFrame(u) {
                    if frame.contains(clickPoint) { return event }
                }
            }

            if !panel.frame.contains(clickPoint) {
                self.dismissPanel()
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissPanel()
        }
    }

    private func scheduleObservationRefresh(for unit: StatusItemUnit) {
        withObservationTracking {
            _ = self.aggregator.perProviderRates
            _ = self.aggregator.perProviderHistory
            _ = self.aggregator.perProviderSessionCount
            _ = self.aggregator.perProviderCostPerMinute
            _ = self.aggregator.providerSummaries
            _ = self.aggregator.spendAlert
            _ = self.connectionManager.state
            _ = self.usageMonitor.currentUsage
            _ = self.usageMonitor.lastError
            _ = self.usageMonitor.isAvailable
            _ = self.codexUsageMonitor.currentUsage
            _ = self.codexUsageMonitor.lastError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.menuHostingView != nil else { return }
                self.refreshPanelContent(for: unit)
                self.scheduleObservationRefresh(for: unit)
            }
        }
    }

    private func refreshPanelContent(for unit: StatusItemUnit) {
        guard let hv = menuHostingView else { return }
        hv.rootView = MenuContentView(
            aggregator: aggregator,
            connectionManager: connectionManager,
            usageMonitor: usageMonitor,
            codexUsageMonitor: codexUsageMonitor,
            filterProviderId: unit.providerId,
            settings: settings,
            onStartDaemon: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async { self?.connectionManager.startDaemonAndConnect() }
            },
            onOpenDashboard: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async { self?.dashboardController.show() }
            },
            onOpenSettings: { [weak self] category in
                self?.dismissPanel()
                DispatchQueue.main.async { self?.settingsController.show(category: category) }
            },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func dismissPanel() {
        panelRefreshTimer?.invalidate()
        panelRefreshTimer = nil
        menuHostingView = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        menuPanel?.close()
        menuPanel = nil
    }

    /// Resolves a non-zero content size from an NSHostingView, falling back
    /// through fittingSize → intrinsicContentSize → current frame size. SwiftUI
    /// layout occasionally hasn't settled on the first read, especially right
    /// after `NSHostingView` is created.
    private func resolvedContentSize(for hostingView: NSHostingView<MenuContentView>) -> NSSize {
        let candidates = [hostingView.fittingSize, hostingView.intrinsicContentSize, hostingView.frame.size]
        return candidates.first(where: { $0.width > 1 && $0.height > 1 }) ?? candidates[0]
    }

    private func statusItemFrame(_ unit: StatusItemUnit) -> NSRect? {
        guard let button = unit.statusItem.button,
              let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - Observation

    /// token rate가 0→nonzero로 전환될 때 usage monitor sleep을 즉시 중단하고 poll 앞당김.
    private var wasTokenActive = false

    private func observeTokenActivity() {
        withObservationTracking {
            _ = aggregator.tokensPerMinute
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isActive = self.aggregator.tokensPerMinute > 0
                if isActive && !self.wasTokenActive {
                    // 토큰이 흐르기 시작했다 = 연결이 살아있다.
                    // 에러 backoff 중인 monitor만 즉시 재시도.
                    if self.usageMonitor.isInBackoff { self.usageMonitor.wakeForImmediatePoll() }
                    if self.codexUsageMonitor.isInTransientBackoff { self.codexUsageMonitor.wakeForImmediatePoll() }
                }
                self.wasTokenActive = isActive
                self.observeTokenActivity()
            }
        }
    }

    private func observeTokenRate() {
        withObservationTracking {
            _ = aggregator.tokensPerMinute
            _ = aggregator.recentHistory
            _ = aggregator.perProviderRates
            _ = aggregator.perProviderHistory
            _ = aggregator.spendAlert
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateAllDisplays()
                self?.observeTokenRate()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.animationStyle
            _ = settings.animationThemeId
            _ = settings.hpBarSource
            _ = settings.defaultTimeRange
            _ = settings.showRateText
            _ = settings.textPosition
            _ = settings.tokenUnit
            _ = settings.graphTimeRange
            _ = settings.providerDisplayMode
            _ = settings.providerSettingsMap
            _ = settings.aggregatedColorName
            _ = settings.widgetOrder
            _ = settings.sleepDelay
            _ = settings.pendingPopupRequest
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.aggregator.timeRange = self.settings.defaultTimeRange
                self.aggregator.graphTimeRange = self.settings.graphTimeRange

                // 위젯 visibility 변경 시 polling 동기화
                self.syncPollingState()

                // Rebuild items if display mode or provider enablement changed
                let needsRebuild = self.needsRebuild()
                if needsRebuild {
                    self.rebuildStatusItems()
                } else {
                    self.updateAllDisplays()
                }

                // Handle popup request from settings
                if let request = self.settings.pendingPopupRequest {
                    self.settings.pendingPopupRequest = nil
                    self.showPopupForRequest(request)
                }

                self.observeSettings()
            }
        }
    }

    // MARK: - Alert Effects

    /// Anomaly detection 상태 변화에 따라 hit/poison 시각 효과 적용.
    private func applyAlertEffects() {
        var alerts: [String: TokenAggregator.SpendAlert] = [:]
        alerts.reserveCapacity(units.count)
        for unit in units {
            if let pid = unit.providerId {
                alerts[pid] = aggregator.perProviderSpendAlerts[pid] ?? .normal
            } else {
                alerts[aggregatedAlertKey] = aggregator.spendAlert
            }
        }
        currentUnitAlerts = alerts

        for unit in units {
            let key = unit.providerId ?? aggregatedAlertKey
            let currentAlert = currentUnitAlerts[key] ?? .normal
            let lastAlert = lastSpendAlerts[key] ?? .normal

            if currentAlert == .critical, lastAlert != .critical {
                unit.playHitEffect()
            }

            if currentAlert == .elevated {
                if !unit.isPoisoned { unit.startPoison() }
            } else if unit.isPoisoned {
                unit.stopPoison()
            }

            lastSpendAlerts[key] = currentAlert
        }

        let hasCritical = currentUnitAlerts.values.contains(.critical)
        if hasCritical, hitEffectTimer == nil {
            hitEffectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for unit in self.units {
                        let key = unit.providerId ?? self.aggregatedAlertKey
                        if self.currentUnitAlerts[key] == .critical { unit.playHitEffect() }
                    }
                }
            }
        } else if !hasCritical, hitEffectTimer != nil {
            hitEffectTimer?.invalidate()
            hitEffectTimer = nil
        }
    }

    // MARK: - Polling Control

    /// 위젯 visibility에 따라 각 usage monitor의 polling을 시작/중단.
    private func syncPollingState() {
        if isClaudeWidgetVisible {
            if !usageMonitor.isPolling { usageMonitor.startPolling() }
        } else {
            usageMonitor.stopPolling()
        }

        guard codexRootResolved else { return }
        if isCodexWidgetVisible {
            if !codexUsageMonitor.isPolling { codexUsageMonitor.startPolling() }
        } else {
            codexUsageMonitor.stopPolling()
        }
    }

    private var isClaudeWidgetVisible: Bool {
        settings.resolvedWidgetOrder().first { $0.id == MenuWidgetItem.claudeUsageId }?.visible ?? true
    }

    private var isCodexWidgetVisible: Bool {
        settings.resolvedWidgetOrder().first { $0.id == MenuWidgetItem.codexUsageId }?.visible ?? true
    }

    private func showPopupForRequest(_ request: AppSettings.PopupRequest) {
        // Dismiss existing panel first
        if menuPanel != nil { dismissPanel() }

        let targetUnit: StatusItemUnit?
        switch request {
        case .mostActive:
            if settings.providerDisplayMode == .aggregated {
                targetUnit = units.first
            } else {
                // Fixed priority: anthropic > openai > others
                let priority = ["anthropic", "openai"]
                let match = priority.first { pid in
                    units.contains { $0.providerId == pid }
                }
                targetUnit = match.flatMap { pid in units.first { $0.providerId == pid } } ?? units.first
            }
        case .provider(let pid):
            targetUnit = units.first { $0.providerId == pid } ?? units.first
        }

        if let unit = targetUnit {
            handleClick(from: unit)
        }
    }

    /// Returns remaining HP (1.0 = full, 0.0 = empty). Negative = no data.
    private func resolveHPBar(source: HPBarSource) -> Double {
        switch source {
        case .none:
            return -1
        case .claudeFiveHour:
            guard let u = usageMonitor.currentUsage?.fiveHour?.utilization else { return -1 }
            return max(0, 1.0 - u / 100)
        case .claudeSevenDay:
            guard let u = usageMonitor.currentUsage?.sevenDay?.utilization else { return -1 }
            return max(0, 1.0 - u / 100)
        case .codexSevenDay:
            guard let primary = codexUsageMonitor.currentUsage?.rateLimit.primaryWindow else { return -1 }
            return max(0, 1.0 - Double(primary.usedPercent) / 100)
        }
    }

    private func needsRebuild() -> Bool {
        switch settings.providerDisplayMode {
        case .aggregated:
            return units.count != 1 || units.first?.providerId != nil
        case .perProvider:
            let enabledIds = ProviderRegistry.configurableProviders
                .filter { settings.effectiveSettings(for: $0.id).enabled }
                .map(\.id)
            let currentIds = units.compactMap(\.providerId)
            return Set(enabledIds) != Set(currentIds)
        }
    }
}
