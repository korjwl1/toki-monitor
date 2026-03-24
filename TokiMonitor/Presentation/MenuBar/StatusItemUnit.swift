import AppKit

/// Encapsulates one NSStatusItem with its own renderers.
@MainActor
final class StatusItemUnit {
    let statusItem: NSStatusItem
    let providerId: String?  // nil = aggregated

    private let characterRenderer = CharacterAnimationRenderer()
    private let sparklineRenderer = SparklineRenderer()
    private var currentStyle: AnimationStyle?

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    init(providerId: String? = nil) {
        self.providerId = providerId
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        setupButton()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: "hare", accessibilityDescription: "Toki Monitor") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            button.image = img
        } else {
            button.title = "🐇"
        }
        button.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        button.imagePosition = .imageTrailing

        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            onRightClick?()
        } else {
            onClick?()
        }
    }

    private var currentThemeId: String?

    /// Update display. tintColor: nil = template/white, non-nil = colored icon/text.
    func update(
        tokensPerMinute: Double,
        history: [Double],
        style: AnimationStyle,
        showRateText: Bool,
        textPosition: TextPosition,
        tokenUnit: TokenUnit,
        tintColor: NSColor? = nil,
        sleepDelay: TimeInterval = 120,
        themeId: String = "rabbit"
    ) {
        // Switch theme if needed
        if currentThemeId != themeId {
            currentThemeId = themeId
            characterRenderer.setTheme(themeId)
        }
        guard let button = statusItem.button else { return }

        let effectiveStyle: AnimationStyle
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            effectiveStyle = .numeric
        } else {
            effectiveStyle = style
        }

        // Full reset on style change — clear everything to prevent ghosting
        if currentStyle != effectiveStyle {
            characterRenderer.stop()
            button.image = nil
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.needsDisplay = true
            currentStyle = effectiveStyle
        }

        switch effectiveStyle {
        case .character:
            characterRenderer.sleepDelay = sleepDelay
            characterRenderer.update(
                tokensPerMinute: tokensPerMinute,
                button: button,
                tintColor: tintColor
            )
            if showRateText {
                let text = TokenFormatter.formatRate(tokensPerMinute, unit: tokenUnit)
                if let tintColor {
                    button.attributedTitle = NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                            .foregroundColor: tintColor,
                        ]
                    )
                } else {
                    button.title = text
                }
                button.imagePosition = textPosition == .leading ? .imageTrailing : .imageLeading
            } else {
                button.title = ""
                button.attributedTitle = NSAttributedString(string: "")
                button.imagePosition = .imageOnly
            }
        case .numeric:
            let text = TokenFormatter.formatRate(tokensPerMinute, unit: tokenUnit)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            ]
            if let tintColor {
                attrs[.foregroundColor] = tintColor
            }
            button.image = nil
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        case .sparkline:
            sparklineRenderer.update(history: history, button: button, tintColor: tintColor)
        }
    }

    func teardown() {
        characterRenderer.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
