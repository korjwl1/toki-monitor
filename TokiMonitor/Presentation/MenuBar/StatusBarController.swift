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
    let settings = AppSettings()
    private lazy var settingsController = SettingsWindowController(settings: settings)

    // Menu panel
    private var menuPanel: NSPanel?
    private var eventMonitor: Any?
    private var globalMonitor: Any?

    init() {
        eventStream = TokiEventStream()
        connectionManager = ConnectionManager(eventStream: eventStream)

        setupEventHandling()
        setupSleepWakeHandling()

        // Apply settings
        aggregator.timeRange = settings.defaultTimeRange
        aggregator.graphTimeRange = settings.graphTimeRange
        aggregator.startSampling()

        // Check daemon status and auto-connect if running
        connectionManager.checkAndConnect()

        // Build initial status items
        rebuildStatusItems()

        // Observe
        observeTokenRate()
        observeSettings()
    }

    // MARK: - Setup

    private func setupEventHandling() {
        eventStream.onEvent = { [weak self] event in
            self?.aggregator.addEvent(event)
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeHandling() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
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
        nc.addObserver(
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
                let tint = Self.nsColor(from: colorName)
                unit.update(
                    tokensPerMinute: rate,
                    history: history,
                    style: style,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint
                )
            } else {
                // Aggregated mode
                let tint: NSColor? = settings.aggregatedColorName.map { Self.nsColor(from: $0) }
                unit.update(
                    tokensPerMinute: aggregator.tokensPerMinute,
                    history: aggregator.recentHistory,
                    style: settings.animationStyle,
                    showRateText: settings.showRateText,
                    textPosition: settings.textPosition,
                    tokenUnit: settings.tokenUnit,
                    tintColor: tint
                )
            }
        }
    }

    private static func nsColor(from colorName: String) -> NSColor {
        switch colorName {
        case "orange": .systemOrange
        case "blue": .systemBlue
        case "green": .systemGreen
        case "purple": .systemPurple
        case "red": .systemRed
        case "pink": .systemPink
        case "yellow": .systemYellow
        case "teal": .systemTeal
        case "indigo": .systemIndigo
        case "mint": .systemMint
        case "cyan": .systemCyan
        case "brown": .systemBrown
        case "gray": .systemGray
        default: .labelColor
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
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.isMovable = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true

        visualEffect.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
        ])

        panel.contentView = visualEffect

        // Position below the clicked status item
        if let button = unit.statusItem.button,
           let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            let panelSize = hostingView.fittingSize
            let x = buttonFrame.midX - panelSize.width / 2
            let y = buttonFrame.minY - panelSize.height - 4
            panel.setFrame(
                NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
                display: true
            )
        }

        panel.orderFrontRegardless()
        menuPanel = panel

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

    private func dismissPanel() {
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

                self.observeSettings()
            }
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
