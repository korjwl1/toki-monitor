import AppKit

/// Renders frame-based character animation in the menu bar.
/// Frames are loaded from Assets.xcassets and cycled at a speed
/// proportional to the animation state.
@MainActor
final class CharacterAnimationRenderer {
    private var frames: [NSImage] = []
    private var currentFrame = 0
    private var timer: Timer?

    init() {
        loadPlaceholderFrames()
    }

    /// Update animation speed based on state. Pass nil to stop.
    func update(state: AnimationState, button: NSStatusBarButton) {
        timer?.invalidate()
        timer = nil

        if state == .idle {
            button.image = frames.first
            button.image?.isTemplate = true
            return
        }

        let interval = 1.0 / state.characterFPS
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.advanceFrame(button: button)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Private

    private func advanceFrame(button: NSStatusBarButton) {
        guard !frames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % frames.count
        button.image = frames[currentFrame]
        button.image?.isTemplate = true
    }

    /// Generate simple placeholder frames (circles of varying size).
    /// Replace with real character assets later.
    private func loadPlaceholderFrames() {
        let size = NSSize(width: 18, height: 18)
        let radii: [CGFloat] = [3, 4, 5, 6, 7, 6, 5, 4]

        frames = radii.map { radius in
            let image = NSImage(size: size, flipped: false) { rect in
                let center = NSPoint(x: rect.midX, y: rect.midY)
                let path = NSBezierPath(
                    ovalIn: NSRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                NSColor.labelColor.setFill()
                path.fill()
                return true
            }
            image.isTemplate = true
            return image
        }
    }
}
