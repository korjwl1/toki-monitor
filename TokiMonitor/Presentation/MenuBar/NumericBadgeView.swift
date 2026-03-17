import AppKit

/// Renders a numeric token rate ("1.2K/m") in the menu bar button.
@MainActor
struct NumericBadgeRenderer {
    func update(tokensPerMinute: Double, button: NSStatusBarButton) {
        let text = TokenAggregator.formatRate(tokensPerMinute)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]

        button.image = nil
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    func clear(button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(string: "")
    }
}
