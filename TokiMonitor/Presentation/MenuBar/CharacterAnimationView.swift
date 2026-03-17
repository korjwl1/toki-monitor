import AppKit

/// Renders frame-based character animation in the menu bar.
/// Loads PNG frames from Resources/CharacterFrames/ and cycles them
/// at a speed proportional to the animation state.
@MainActor
final class CharacterAnimationRenderer {
    private var frames: [NSImage] = []
    private var currentFrame = 0
    private var timer: Timer?

    init() {
        loadFrames()
    }

    /// Update animation speed based on state.
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
        currentFrame = 0
    }

    // MARK: - Private

    private func advanceFrame(button: NSStatusBarButton) {
        guard !frames.isEmpty else { return }
        currentFrame = (currentFrame + 1) % frames.count
        button.image = frames[currentFrame]
        button.image?.isTemplate = true
    }

    private func loadFrames() {
        let bundle = Bundle.main
        let frameCount = 8

        frames = (0..<frameCount).compactMap { i in
            let name = String(format: "frame_%02d", i)
            guard let url = bundle.url(
                forResource: name,
                withExtension: "png",
                subdirectory: "CharacterFrames"
            ) else {
                return nil
            }
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        // Fallback: if no frames found, generate simple placeholders
        if frames.isEmpty {
            frames = generatePlaceholderFrames()
        }
    }

    private func generatePlaceholderFrames() -> [NSImage] {
        let size = NSSize(width: 18, height: 18)
        let radii: [CGFloat] = [3, 4, 5, 6, 7, 6, 5, 4]

        return radii.map { radius in
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
