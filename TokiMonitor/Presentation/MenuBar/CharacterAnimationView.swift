import AppKit

/// Renders frame-based character animation in the menu bar.
/// Loads frames from the active AnimationTheme.
@MainActor
final class CharacterAnimationRenderer {
    private var theme: AnimationTheme?
    private var currentFrame = 0
    private var frameTimer: Timer?
    private let mapper = AnimationStateMapper()
    private var currentInterval: TimeInterval = 0
    private var currentTintColor: NSColor?
    private var isStopped = false

    private var idleSince: Date?
    private var isSleeping = false

    var sleepDelay: TimeInterval = 120

    private var frames: [NSImage] { theme?.runFrames ?? [] }
    private var sleepFrames: [NSImage] { theme?.sleepFrames ?? [] }

    init() {
        loadDefaultTheme()
    }

    /// Switch to a different animation theme by ID.
    func setTheme(_ themeId: String) {
        let themes = AnimationTheme.discoverAll()
        if let match = themes.first(where: { $0.config.id == themeId }) {
            theme = match
            currentFrame = 0
        }
    }

    func update(tokensPerMinute: Double, button: NSStatusBarButton, tintColor: NSColor? = nil) {
        isStopped = false
        currentTintColor = tintColor
        let idle = mapper.isIdle(tokensPerMinute: tokensPerMinute)

        if idle {
            if idleSince == nil { idleSince = Date() }

            let idleDuration = Date().timeIntervalSince(idleSince!)
            if idleDuration >= sleepDelay, !sleepFrames.isEmpty {
                if !isSleeping {
                    isSleeping = true
                    currentFrame = 0
                    startSleepAnimation(button: button)
                }
            } else {
                if isSleeping { isSleeping = false; stopAnimation() }
                stopAnimation()
                applyFrame(0, from: frames, to: button)
            }
            return
        }

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

    private func loadDefaultTheme() {
        let themes = AnimationTheme.discoverAll()
        // Default to "rabbit", fallback to first available
        theme = themes.first(where: { $0.config.id == "rabbit" }) ?? themes.first

        // Fallback: load from legacy CharacterFrames location
        if theme == nil {
            loadLegacyFrames()
        }
    }

    private func loadLegacyFrames() {
        let bundle = Bundle.main
        let frameSize = NSSize(width: 24, height: 18)
        let canvasSize = NSSize(width: 28, height: 18)

        var runFrames: [NSImage] = []
        for i in 0..<7 {
            let name = String(format: "frame_%02d", i)
            guard let url = bundle.url(forResource: name, withExtension: "png"),
                  let src = NSImage(contentsOf: url) else { continue }
            src.size = frameSize
            let canvas = NSImage(size: canvasSize, flipped: false) { _ in
                src.draw(in: NSRect(origin: .zero, size: frameSize))
                return true
            }
            canvas.isTemplate = true
            runFrames.append(canvas)
        }

        guard !runFrames.isEmpty else {
            // Ultimate fallback: placeholder circles
            let placeholderConfig = AnimationThemeConfig(
                id: "placeholder", name: "Placeholder",
                frameSize: [18, 18], canvasSize: [18, 18],
                sleep: .init(mode: "overlay")
            )
            let placeholders = generatePlaceholderFrames()
            theme = AnimationTheme(
                config: placeholderConfig,
                runFrames: placeholders,
                sleepFrames: []
            )
            return
        }

        let config = AnimationThemeConfig(
            id: "rabbit", name: "Rabbit",
            frameSize: [24, 18], canvasSize: [28, 18],
            sleep: .init(mode: "overlay", textOffset: [-7, -1], fontSize: 5, interval: 0.8)
        )
        let sleepFrames = AnimationTheme.generateOverlaySleepFrames(base: runFrames[0], config: config)
        theme = AnimationTheme(config: config, runFrames: runFrames, sleepFrames: sleepFrames)
    }

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
            Task { @MainActor in self.advanceFrame(button: button) }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func startSleepAnimation(button: NSStatusBarButton) {
        frameTimer?.invalidate()
        let interval = theme?.config.sleepInterval ?? 0.8
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
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private func generatePlaceholderFrames() -> [NSImage] {
        let size = NSSize(width: 18, height: 18)
        return [3, 4, 5, 6, 7, 6, 5, 4].map { radius in
            let r = CGFloat(radius)
            let image = NSImage(size: size, flipped: false) { rect in
                let path = NSBezierPath(ovalIn: NSRect(
                    x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2
                ))
                NSColor.labelColor.setFill()
                path.fill()
                return true
            }
            image.isTemplate = true
            return image
        }
    }
}
