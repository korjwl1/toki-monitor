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
    private lazy var settingsController = SettingsWindowController(settings: settings)

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

        // Check daemon status and auto-connect if running
        connectionManager.checkAndConnect()

        // Apply initial display style
        updateMenuBarDisplay()

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
        let menuWidth: CGFloat = 280

        // --- Connection status section ---
        if connectionManager.state.isConnected {
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
                .frame(width: menuWidth)
            )
            headerView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 60)
            headerItem.view = headerView
            menu.addItem(headerItem)
            menu.addItem(.separator())

            if aggregator.providerSummaries.isEmpty {
                let emptyItem = NSMenuItem()
                let emptyView = NSHostingView(rootView:
                    Text("이벤트 대기 중...")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: menuWidth, height: 30)
                )
                emptyView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 30)
                emptyItem.view = emptyView
                menu.addItem(emptyItem)
            } else {
                if let total = aggregator.totalSummary {
                    let totalItem = NSMenuItem()
                    let totalView = NSHostingView(rootView:
                        TotalSummaryView(total: total)
                            .padding(.horizontal, 12)
                            .frame(width: menuWidth)
                    )
                    totalView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 44)
                    totalItem.view = totalView
                    menu.addItem(totalItem)
                    menu.addItem(.separator())
                }

                for summary in aggregator.providerSummaries {
                    let item = NSMenuItem()
                    let rowView = NSHostingView(rootView:
                        ProviderRowView(summary: summary)
                            .padding(.horizontal, 12)
                            .frame(width: menuWidth)
                    )
                    rowView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 44)
                    item.view = rowView
                    menu.addItem(item)
                }
            }
        } else {
            let disconnectedItem = NSMenuItem()
            let disconnectedView = NSHostingView(rootView:
                VStack(spacing: 8) {
                    HStack {
                        Text("Toki Monitor")
                            .font(.headline)
                        Spacer()
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("미연결").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: menuWidth)
            )
            disconnectedView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 36)
            disconnectedItem.view = disconnectedView
            menu.addItem(disconnectedItem)
            menu.addItem(.separator())

            let startItem = NSMenuItem(title: "toki 데몬 시작", action: #selector(startDaemon), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // --- Settings inline ---
        let settingsItem = NSMenuItem()
        let settingsView = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 10) {
                Text("메뉴바 스타일")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { self.settings.animationStyle },
                    set: { self.settings.animationStyle = $0 }
                )) {
                    Text("캐릭터").tag(AnimationStyle.character)
                    Text("수치").tag(AnimationStyle.numeric)
                    Text("그래프").tag(AnimationStyle.sparkline)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(width: menuWidth)
        )
        settingsView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 56)
        settingsItem.view = settingsView
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // --- Always visible items ---
        let dashItem = NSMenuItem(title: "대시보드", action: #selector(openDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        let fullSettingsItem = NSMenuItem(title: "설정...", action: #selector(openSettings), keyEquivalent: ",")
        fullSettingsItem.target = self
        menu.addItem(fullSettingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openDashboard() {
        dashboardController.show()
    }

    @objc private func startDaemon() {
        connectionManager.startDaemonAndConnect()
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Animation

    private var currentStyle: AnimationStyle?

    private func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        let effectiveStyle: AnimationStyle
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            effectiveStyle = .numeric
        } else {
            effectiveStyle = settings.animationStyle
        }

        // Full reset only when style changes
        if currentStyle != effectiveStyle {
            characterRenderer.stop()
            numericRenderer.clear(button: button)
            button.image = nil
            button.attributedTitle = NSAttributedString(string: "")
            currentStyle = effectiveStyle
        }

        // Update current style's display
        switch effectiveStyle {
        case .character:
            // Only restart timer if animation state changed (handled inside renderer)
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
