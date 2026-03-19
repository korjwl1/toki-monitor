import AppKit

/// Renders a numeric token rate ("1.2K/m") in the menu bar button.
@MainActor
struct NumericBadgeRenderer {
    func update(tokensPerMinute: Double, button: NSStatusBarButton) {
        let text = TokenFormatter.formatRate(tokensPerMinute)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
        ]

        button.image = nil
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
    }

    func clear(button: NSStatusBarButton) {
        button.attributedTitle = NSAttributedString(string: "")
    }
}
