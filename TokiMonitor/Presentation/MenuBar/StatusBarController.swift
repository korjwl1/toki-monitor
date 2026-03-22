import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let connectionManager: ConnectionManager
    private let eventStream: TokiEventStream
    private let aggregator = TokenAggregator()

    // Status item units (single for aggregated, multiple for perProvider)
    private var units: [StatusItemUnit] = []

    // Dashboard & Settings
    private let dashboardController = DashboardWindowController()
    let settings: AppSettings = {
        let s = AppSettings()
        L.settings = s
        return s
    }()
    private lazy var settingsController = SettingsWindowController(settings: settings, oauthManager: oauthManager)

    // Claude OAuth + Usage
    private let oauthManager = ClaudeOAuthManager()
    private lazy var usageMonitor = ClaudeUsageMonitor(
        oauthManager: oauthManager,
        aggregator: aggregator,
        settings: settings
    )

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
        aggregator.timeRange = settings.defaultTimeRange
        aggregator.graphTimeRange = settings.graphTimeRange
        aggregator.startSampling()
        usageMonitor.startPolling()

        // Check daemon status and auto-connect if running
        connectionManager.checkAndConnect()

        // Build initial status items
        rebuildStatusItems()

        // Observe
        observeTokenRate()
        observeSettings()
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
            units.append(unit)

        case .perProvider:
            let providers = ProviderRegistry.configurableProviders.filter { provider in
                settings.effectiveSettings(for: provider.id).enabled
            }
            for provider in providers {
                let unit = StatusItemUnit(providerId: provider.id)
                unit.onClick = { [weak self] in self?.handleClick(from: unit) }
                units.append(unit)
            }
            // Fallback: at least one unit
            if units.isEmpty {
                let unit = StatusItemUnit(providerId: nil)
                unit.onClick = { [weak self] in self?.handleClick(from: unit) }
                units.append(unit)
            }
        }

        updateAllDisplays()
    }

    private func updateAllDisplays() {
        for unit in units {
            if let pid = unit.providerId {
                // Per-provider mode — use provider's theme color
                let rate = aggregator.perProviderRates[pid] ?? 0
                let history = aggregator.perProviderHistory[pid] ?? []
                let style = settings.effectiveStyle(for: pid)
                let colorName = settings.effectiveColorName(
                    for: ProviderRegistry.allProviders.first { $0.id == pid } ?? ProviderRegistry.unknown
                )
                let tint = ProviderInfo.nsColorFromName( colorName)
                unit.update(
                    tokensPerMinute: rate,
                    history: history,
                    style: style,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint,
                    sleepDelay: settings.sleepDelay.interval
                )
            } else {
                // Aggregated mode
                let tint: NSColor? = settings.aggregatedColorName.map { ProviderInfo.nsColorFromName( $0) }
                unit.update(
                    tokensPerMinute: aggregator.tokensPerMinute,
                    history: aggregator.recentHistory,
                    style: settings.animationStyle,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint,
                    sleepDelay: settings.sleepDelay.interval
                )
            }
        }
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
            onOpenSettings: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async {
                    self?.settingsController.show()
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.sizingOptions = [.minSize]
        if #available(macOS 14.0, *) {
            hostingView.safeAreaRegions = []
        }
        hostingView.setFrameSize(hostingView.fittingSize)
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

        // Position below the clicked status item
        if let button = unit.statusItem.button,
           let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let contentSize = hostingView.fittingSize
            let screenFrame = NSScreen.main?.visibleFrame ?? .zero

            // Set content size — panel auto-calculates frame including titlebar
            panel.setContentSize(contentSize)
            let panelSize = panel.frame.size

            // Align panel left edge to button left edge (standard macOS menu behavior)
            var x = buttonFrame.minX
            if x + panelSize.width > screenFrame.maxX {
                x = screenFrame.maxX - panelSize.width - 4
            }
            if x < screenFrame.minX {
                x = screenFrame.minX + 4
            }
            let y = buttonFrame.minY - panelSize.height - 4
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
            _ = self.aggregator.providerSummaries
            _ = self.connectionManager.state
            _ = self.usageMonitor.currentUsage
            _ = self.usageMonitor.lastError
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
            onOpenSettings: { [weak self] in
                self?.dismissPanel()
                DispatchQueue.main.async { self?.settingsController.show() }
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

    private func statusItemFrame(_ unit: StatusItemUnit) -> NSRect? {
        guard let button = unit.statusItem.button,
              let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - Observation

    private func observeTokenRate() {
        withObservationTracking {
            _ = aggregator.tokensPerMinute
            _ = aggregator.recentHistory
            _ = aggregator.perProviderRates
            _ = aggregator.perProviderHistory
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
