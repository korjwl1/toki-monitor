import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem

    init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        setupButton()
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

    @objc private func handleClick() {
        // TODO: WP01 — show popover or disconnected view
    }
}
