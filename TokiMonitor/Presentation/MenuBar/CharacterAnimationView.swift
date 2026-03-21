import AppKit

/// Renders frame-based character animation in the menu bar.
@MainActor
final class CharacterAnimationRenderer {
    private var frames: [NSImage] = []
    private var currentFrame = 0
    private var frameTimer: Timer?
    private let mapper = AnimationStateMapper()
    private var currentInterval: TimeInterval = 0
    private var currentTintColor: NSColor?
    private var isStopped = false

    init() {
        loadFrames()
    }

    func update(tokensPerMinute: Double, button: NSStatusBarButton, tintColor: NSColor? = nil) {
        isStopped = false
        currentTintColor = tintColor
        let idle = mapper.isIdle(tokensPerMinute: tokensPerMinute)

        if idle {
            stopAnimation()
            applyFrame(0, to: button)
            return
        }

        let newInterval = mapper.interval(for: tokensPerMinute)

        let threshold = 0.1
        if frameTimer != nil,
           currentInterval > 0,
           abs(newInterval - currentInterval) / currentInterval < threshold {
            return
        }

        startAnimation(interval: newInterval, button: button)
    }

    func stop() {
        isStopped = true
        stopAnimation()
        currentFrame = 0
    }

    // MARK: - Private

    private func applyFrame(_ index: Int, to button: NSStatusBarButton) {
        guard index < frames.count else { return }
        let frame = frames[index]
        if let tint = currentTintColor {
            button.image = tintedImage(frame, color: tint)
            button.image?.isTemplate = false
        } else {
            button.image = frame
            button.image?.isTemplate = true
        }
    }

    private func startAnimation(interval: TimeInterval, button: NSStatusBarButton) {
        frameTimer?.invalidate()
        currentInterval = interval

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.advanceFrame(button: button)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        currentInterval = 0
    }

    private func advanceFrame(button: NSStatusBarButton) {
        guard !frames.isEmpty, !isStopped else { return }
        currentFrame = (currentFrame + 1) % frames.count
        applyFrame(currentFrame, to: button)
    }

    private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }

    private func loadFrames() {
        let bundle = Bundle.main
        let frameCount = 7

        frames = (0..<frameCount).compactMap { i in
            let name = String(format: "frame_%02d", i)
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            image.size = NSSize(width: 24, height: 18)
            image.isTemplate = true
            return image
        }

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
