import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let connectionManager: ConnectionManager
    private let eventStream: TokiEventStream
    private let aggregator = TokenAggregator()

    // Animation renderers
    private let characterRenderer = CharacterAnimationRenderer()
    private let numericRenderer = NumericBadgeRenderer()
    private let sparklineRenderer = SparklineRenderer()

    // Dashboard & Settings
    private let dashboardController = DashboardWindowController()
    private let settings = AppSettings()

    init() {
        eventStream = TokiEventStream()
        connectionManager = ConnectionManager(eventStream: eventStream)

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        setupButton()
        setupEventHandling()

        // Apply settings
        aggregator.timeRange = settings.defaultTimeRange
        aggregator.startSampling()

        // Don't auto-connect — user clicks "toki 시작"

        // Observe
        observeAnimationState()
        observeSettings()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: "hare", accessibilityDescription: "Toki Monitor") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "🐇"
        }
        button.action = #selector(handleClick)
        button.target = self
    }

    private func setupEventHandling() {
        eventStream.onEvent = { [weak self] event in
            self?.aggregator.addEvent(event)
        }
    }

    // MARK: - Click → NSMenu

    @objc private func handleClick() {
        let menu = NSMenu()

        if connectionManager.state.isConnected {
            // Header
            let headerItem = NSMenuItem()
            let headerView = NSHostingView(rootView:
                VStack(spacing: 4) {
                    HStack {
                        Text("Toki Monitor")
                            .font(.headline)
                        Spacer()
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("연결됨").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(TokenFormatter.formatRate(aggregator.tokensPerMinute))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: 280)
            )
            headerView.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
            headerItem.view = headerView
            menu.addItem(headerItem)
            menu.addItem(.separator())

            // Provider rows
            if aggregator.providerSummaries.isEmpty {
                let emptyItem = NSMenuItem()
                let emptyView = NSHostingView(rootView:
                    Text("이벤트 대기 중...")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 280, height: 30)
                )
                emptyView.frame = NSRect(x: 0, y: 0, width: 280, height: 30)
                emptyItem.view = emptyView
                menu.addItem(emptyItem)
            } else {
                if let total = aggregator.totalSummary {
                    let totalItem = NSMenuItem()
                    let totalView = NSHostingView(rootView:
                        TotalSummaryView(total: total)
                            .padding(.horizontal, 12)
                            .frame(width: 280)
                    )
                    totalView.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
                    totalItem.view = totalView
                    menu.addItem(totalItem)
                    menu.addItem(.separator())
                }

                for summary in aggregator.providerSummaries {
                    let item = NSMenuItem()
                    let rowView = NSHostingView(rootView:
                        ProviderRowView(summary: summary)
                            .padding(.horizontal, 12)
                            .frame(width: 280)
                    )
                    rowView.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
                    item.view = rowView
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())

            // Dashboard
            let dashItem = NSMenuItem(title: "대시보드", action: #selector(openDashboard), keyEquivalent: "d")
            dashItem.target = self
            menu.addItem(dashItem)

        } else {
            // Disconnected
            let disconnectedItem = NSMenuItem()
            let disconnectedView = NSHostingView(rootView:
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("toki 데몬 미연결")
                        .font(.headline)
                    Text("toki 데몬이 실행되지 않고 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 260)
            )
            disconnectedView.frame = NSRect(x: 0, y: 0, width: 260, height: 110)
            disconnectedItem.view = disconnectedView
            menu.addItem(disconnectedItem)
            menu.addItem(.separator())

            let startItem = NSMenuItem(title: "toki 시작", action: #selector(startDaemon), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Reset so next click goes to action, not menu
    }

    @objc private func openDashboard() {
        dashboardController.show()
    }

    @objc private func startDaemon() {
        connectionManager.startDaemonAndConnect()
    }

    @objc private func openSettings() {
        // TODO: open settings window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Animation

    private func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        let effectiveStyle: AnimationStyle
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            effectiveStyle = .numeric
        } else {
            effectiveStyle = settings.animationStyle
        }

        characterRenderer.stop()
        numericRenderer.clear(button: button)

        guard connectionManager.state.isConnected else {
            if let img = NSImage(systemSymbolName: "hare", accessibilityDescription: "Toki Monitor - Disconnected") {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            }
            return
        }

        switch effectiveStyle {
        case .character:
            characterRenderer.update(state: aggregator.animationState, button: button)
        case .numeric:
            numericRenderer.update(tokensPerMinute: aggregator.tokensPerMinute, button: button)
        case .sparkline:
            sparklineRenderer.update(history: aggregator.recentHistory, button: button)
        }
    }

    // MARK: - Observation

    private func observeAnimationState() {
        withObservationTracking {
            _ = aggregator.animationState
            _ = aggregator.recentHistory
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateMenuBarDisplay()
                self?.observeAnimationState()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.animationStyle
            _ = settings.defaultTimeRange
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.aggregator.timeRange = self?.settings.defaultTimeRange ?? .oneHour
                self?.updateMenuBarDisplay()
                self?.observeSettings()
            }
        }
    }
}
