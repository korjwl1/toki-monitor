import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let connectionManager: ConnectionManager
    private let eventStream: TokiEventStream

    init() {
        eventStream = TokiEventStream()
        connectionManager = ConnectionManager(eventStream: eventStream)

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        setupButton()
        setupPopover()

        // Auto-connect on launch
        connectionManager.connect()

        // Observe connection state changes
        observeState()
    }

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

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            updatePopoverContent()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure popover gets focus
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updatePopoverContent() {
        if connectionManager.state.isConnected {
            // TODO: WP03 — show provider summary popover
            let placeholder = NSHostingController(
                rootView: VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("toki 연결됨")
                        .font(.headline)
                    Text("이벤트 대기 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 260)
            )
            popover.contentViewController = placeholder
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

    private func observeState() {
        // Poll state changes via withObservationTracking
        withObservationTracking {
            _ = connectionManager.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handleStateChange()
            }
        }
    }

    private func handleStateChange() {
        updateIcon()
        if popover.isShown {
            updatePopoverContent()
        }
        // Re-observe
        observeState()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbolName: String
        switch connectionManager.state {
        case .connected:
            symbolName = "brain.head.profile"
        case .disconnected:
            symbolName = "brain.head.profile.slash"
        case .reconnecting:
            symbolName = "brain.head.profile.slash"
        }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Toki Monitor"
        )
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
    }
}
