import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let connectionManager: ConnectionManager
    private let eventStream: TokiEventStream
    private let aggregator = TokenAggregator()

    // Animation renderers
    private let characterRenderer = CharacterAnimationRenderer()
    private let numericRenderer = NumericBadgeRenderer()
    private let sparklineRenderer = SparklineRenderer()

    // Current style — TODO: WP05 move to AppSettings
    private var animationStyle: AnimationStyle = .sparkline

    init() {
        eventStream = TokiEventStream()
        connectionManager = ConnectionManager(eventStream: eventStream)

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        setupButton()
        setupPopover()
        setupEventHandling()

        // Start aggregator sampling for sparkline
        aggregator.startSampling()

        // Auto-connect on launch
        connectionManager.connect()

        // Observe state changes
        observeConnectionState()
        observeAnimationState()
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "brain.head.profile",
            accessibilityDescription: "Toki Monitor"
        )
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        updatePopoverContent()
    }

    private func setupEventHandling() {
        eventStream.onEvent = { [weak self] event in
            self?.aggregator.addEvent(event)
        }
    }

    // MARK: - Click

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Popover Content

    private func updatePopoverContent() {
        if connectionManager.state.isConnected {
            let contentView = PopoverContentView(
                summaries: aggregator.providerSummaries,
                total: aggregator.totalSummary,
                timeRange: aggregator.timeRange,
                tokensPerMinute: aggregator.tokensPerMinute,
                onTimeRangeChange: { [weak self] range in
                    self?.aggregator.timeRange = range
                },
                onDashboardTap: {
                    // TODO: WP04 — open dashboard window
                },
                onSettingsTap: {
                    // TODO: WP05 — open settings
                }
            )
            popover.contentViewController = NSHostingController(rootView: contentView)
        } else {
            let disconnectedView = DisconnectedView(
                state: connectionManager.state,
                onStartDaemon: { [weak self] in
                    self?.connectionManager.startDaemonAndConnect()
                }
            )
            popover.contentViewController = NSHostingController(rootView: disconnectedView)
        }
    }

    // MARK: - Animation

    private func updateMenuBarDisplay() {
        guard let button = statusItem.button else { return }

        // Reduce Motion → force numeric
        let effectiveStyle: AnimationStyle
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            effectiveStyle = .numeric
        } else {
            effectiveStyle = animationStyle
        }

        // Stop any previous animation
        characterRenderer.stop()
        numericRenderer.clear(button: button)

        guard connectionManager.state.isConnected else {
            updateDisconnectedIcon()
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

    private func updateDisconnectedIcon() {
        guard let button = statusItem.button else { return }
        characterRenderer.stop()
        numericRenderer.clear(button: button)
        button.image = NSImage(
            systemSymbolName: "brain.head.profile.slash",
            accessibilityDescription: "Toki Monitor - Disconnected"
        )
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
    }

    // MARK: - Observation

    private func observeConnectionState() {
        withObservationTracking {
            _ = connectionManager.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleConnectionChange()
            }
        }
    }

    private func handleConnectionChange() {
        updateMenuBarDisplay()
        if popover.isShown {
            updatePopoverContent()
        }
        observeConnectionState()
    }

    private func observeAnimationState() {
        withObservationTracking {
            _ = aggregator.animationState
            _ = aggregator.recentHistory
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleAnimationChange()
            }
        }
    }

    private func handleAnimationChange() {
        updateMenuBarDisplay()
        observeAnimationState()
    }
}
