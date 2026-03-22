import AppKit

/// Renders frame-based character animation in the menu bar.
@MainActor
final class CharacterAnimationRenderer {
    private var frames: [NSImage] = []
    private var sleepFrames: [NSImage] = []
    private var currentFrame = 0
    private var frameTimer: Timer?
    private let mapper = AnimationStateMapper()
    private var currentInterval: TimeInterval = 0
    private var currentTintColor: NSColor?
    private var isStopped = false

    /// Tracks when idle state began, to trigger sleep animation after threshold.
    private var idleSince: Date?
    private var isSleeping = false

    /// Resolved from AppSettings.sleepDelay
    var sleepDelay: TimeInterval = 120

    /// Shared canvas size for all frames (running + sleep)
    private static let canvasSize = NSSize(width: 28, height: 18)

    init() {
        loadFrames()
    }

    func update(tokensPerMinute: Double, button: NSStatusBarButton, tintColor: NSColor? = nil) {
        isStopped = false
        currentTintColor = tintColor
        let idle = mapper.isIdle(tokensPerMinute: tokensPerMinute)

        if idle {
            if idleSince == nil {
                idleSince = Date()
            }

            let idleDuration = Date().timeIntervalSince(idleSince!)

            if idleDuration >= sleepDelay, !sleepFrames.isEmpty {
                if !isSleeping {
                    isSleeping = true
                    currentFrame = 0
                    startSleepAnimation(button: button)
                }
            } else {
                if isSleeping {
                    isSleeping = false
                    stopAnimation()
                }
                stopAnimation()
                applyFrame(0, from: frames, to: button)
            }
            return
        }

        // Active — reset idle/sleep state
        idleSince = nil
        if isSleeping {
            isSleeping = false
            stopAnimation()
            currentFrame = 0
        }

        let newInterval = mapper.interval(for: tokensPerMinute)

        let threshold = 0.1
        if frameTimer != nil,
           currentInterval > 0,
           !isSleeping,
           abs(newInterval - currentInterval) / currentInterval < threshold {
            return
        }

        startAnimation(interval: newInterval, button: button)
    }

    func stop() {
        isStopped = true
        isSleeping = false
        idleSince = nil
        stopAnimation()
        currentFrame = 0
    }

    // MARK: - Private

    private func applyFrame(_ index: Int, from source: [NSImage], to button: NSStatusBarButton) {
        guard index < source.count else { return }
        let frame = source[index]
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

    private func startSleepAnimation(button: NSStatusBarButton) {
        frameTimer?.invalidate()
        let interval: TimeInterval = 0.8
        currentInterval = interval

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.isSleeping, !self.sleepFrames.isEmpty, !self.isStopped else { return }
                self.currentFrame = (self.currentFrame + 1) % self.sleepFrames.count
                self.applyFrame(self.currentFrame, from: self.sleepFrames, to: button)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer

        applyFrame(0, from: sleepFrames, to: button)
    }

    private func stopAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        currentInterval = 0
    }

    private func advanceFrame(button: NSStatusBarButton) {
        guard !frames.isEmpty, !isStopped, !isSleeping else { return }
        currentFrame = (currentFrame + 1) % frames.count
        applyFrame(currentFrame, from: frames, to: button)
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

    // MARK: - Frame Loading

    private func loadFrames() {
        let bundle = Bundle.main
        let frameCount = 7

        let rabbitSize = NSSize(width: 24, height: 18)
        frames = (0..<frameCount).compactMap { i in
            let name = String(format: "frame_%02d", i)
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                  let src = NSImage(contentsOf: url) else { return nil }
            src.size = rabbitSize
            let canvas = NSImage(size: Self.canvasSize, flipped: false) { _ in
                src.draw(in: NSRect(origin: .zero, size: rabbitSize))
                return true
            }
            canvas.isTemplate = true
            return canvas
        }

        if frames.isEmpty {
            frames = generatePlaceholderFrames()
        }

        // Generate sleep frames from frame_00 + "z" overlay
        generateSleepFrames()
    }

    /// Generates 4 sleep frames by compositing frame_00 with z text overlay.
    /// Frame 0: rabbit only (same as idle)
    /// Frame 1: rabbit + "z"
    /// Frame 2: rabbit + "zZ"
    /// Frame 3: rabbit + "zZZ"
    private func generateSleepFrames() {
        guard let baseFrame = frames.first else { return }

        let zTexts = ["", "z", "zZ"]
        // Canvas wider than base to accommodate z text without shifting rabbit
        let canvasSize = Self.canvasSize

        // Rabbit drawn at left, z text at upper-right of rabbit
        let rabbitX: CGFloat = 0.0
        let rabbitRect = NSRect(origin: NSPoint(x: rabbitX, y: 0), size: baseFrame.size)

        sleepFrames = zTexts.map { zText in
            let image = NSImage(size: canvasSize, flipped: false) { rect in
                // Draw the base rabbit
                baseFrame.draw(in: rabbitRect)

                if !zText.isEmpty {
                    // Draw z text at upper-right, above rabbit's head
                    let fontSize: CGFloat = 5.0
                    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                    let attrStr = NSAttributedString(string: zText, attributes: attrs)
                    let textSize = attrStr.size()
                    // Position: right side of rabbit, top area
                    let textX = rabbitRect.maxX - 7
                    let textY = rect.maxY - textSize.height - 1
                    attrStr.draw(at: NSPoint(x: textX, y: textY))
                }

                return true
            }
            image.isTemplate = true
            return image
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
