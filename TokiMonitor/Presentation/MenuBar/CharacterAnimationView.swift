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
    private var sleepCheckTimer: Timer?

    var sleepDelay: TimeInterval = 120

    /// 0.0–1.0, set externally. Draws a thin bar at the top of the canvas.
    var hpBarValue: Double = 0

    private var isPlayingHitEffect = false
    private weak var hitOverlay: HitStarView?

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
                // Schedule a one-shot timer to transition to sleep
                // (in case update() isn't called again while idle)
                scheduleSleepCheck(button: button)
            }
            return
        }

        idleSince = nil
        sleepCheckTimer?.invalidate()
        sleepCheckTimer = nil
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
        sleepCheckTimer?.invalidate()
        sleepCheckTimer = nil
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

    private weak var hpBarView: HPBarView?

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

        // Update HP bar overlay (native NSView, not image composite)
        // hpBarValue < 0 means no data / source is none
        updateHPBar(on: button)
    }

    private func updateHPBar(on button: NSStatusBarButton) {
        if hpBarValue < 0 {
            hpBarView?.removeFromSuperview()
            return
        }

        let bar: HPBarView
        if let existing = hpBarView {
            bar = existing
        } else {
            bar = HPBarView()
            button.addSubview(bar)
            hpBarView = bar
        }

        let config = theme?.config
        let charWidth = CGFloat(config?.frameSize[0] ?? 24)
        let barHeight = config?.hpBarHeight ?? 2
        let widthRatio = config?.hpBarWidthRatio ?? 0.7
        let yOffset = config?.hpBarYOffset ?? 1
        let xOffset = config?.hpBarXOffset ?? 0

        let barWidth = charWidth * widthRatio

        // Ask the button cell where it actually draws the image
        let imgRect = button.cell?.imageRect(forBounds: button.bounds)
            ?? NSRect(x: (button.bounds.width - charWidth) / 2, y: 0, width: charWidth, height: button.bounds.height)

        let charCenterX = imgRect.origin.x + charWidth / 2
        let barX = charCenterX - barWidth / 2 + xOffset

        bar.frame = NSRect(
            x: barX,
            y: yOffset,
            width: barWidth,
            height: barHeight
        )
        bar.value = hpBarValue
        bar.needsDisplay = true
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

    private func scheduleSleepCheck(button: NSStatusBarButton) {
        sleepCheckTimer?.invalidate()
        guard let idleSince, !isSleeping else { return }
        let remaining = sleepDelay - Date().timeIntervalSince(idleSince)
        guard remaining > 0 else { return }

        sleepCheckTimer = Timer.scheduledTimer(withTimeInterval: remaining + 0.1, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped, !self.isSleeping, !self.sleepFrames.isEmpty else { return }
                self.isSleeping = true
                self.currentFrame = 0
                self.startSleepAnimation(button: button)
            }
        }
    }

    private func advanceFrame(button: NSStatusBarButton) {
        guard !frames.isEmpty, !isStopped, !isSleeping else { return }
        currentFrame = (currentFrame + 1) % frames.count
        applyFrame(currentFrame, from: frames, to: button)
    }

    // MARK: - Hit Effect

    func playHitEffect(on button: NSStatusBarButton) {
        guard !isPlayingHitEffect else { return }
        isPlayingHitEffect = true

        let imgRect = button.cell?.imageRect(forBounds: button.bounds)
            ?? button.bounds

        // Spawn 2 star bursts at random positions over the character, different sizes
        let sizes: [CGFloat] = [7, 4]
        var stars: [HitStarView] = []

        for size in sizes {
            let maxX = imgRect.maxX - size
            let maxY = imgRect.maxY - size
            let x = CGFloat.random(in: imgRect.origin.x...max(imgRect.origin.x, maxX))
            let y = CGFloat.random(in: imgRect.origin.y...max(imgRect.origin.y, maxY))

            let star = HitStarView(frame: NSRect(x: x, y: y, width: size, height: size))
            star.wantsLayer = true
            star.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let rotation = CGFloat.random(in: -0.6...0.6)  // ~±35°
            star.frameCenterRotation = rotation * 180 / .pi
            button.addSubview(star)
            stars.append(star)
        }

        // Shake — shift the character image inside fixed canvas with damped oscillation
        let originalImage = button.image
        let canvasSize = originalImage?.size ?? NSSize(width: 24, height: 18)
        let duration = 0.4
        let totalFrames = 24  // ~60fps for 0.4s
        let amplitude: CGFloat = 3.5
        let frequency: CGFloat = 3.5  // oscillations

        for i in 0...totalFrames {
            let t = Double(i) / Double(totalFrames)
            DispatchQueue.main.asyncAfter(deadline: .now() + t * duration) {
                guard let src = originalImage else { return }
                let decay = 1.0 - CGFloat(t)
                let dx = amplitude * decay * sin(CGFloat(t) * frequency * 2 * .pi)

                if abs(dx) < 0.3 && i == totalFrames {
                    button.image = src
                    return
                }
                let shifted = NSImage(size: canvasSize, flipped: false) { _ in
                    src.draw(at: NSPoint(x: dx, y: 0),
                             from: NSRect(origin: .zero, size: canvasSize),
                             operation: .sourceOver, fraction: 1)
                    return true
                }
                shifted.isTemplate = src.isTemplate
                button.image = shifted
            }
        }

        // Stars scale up then fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for star in stars {
                star.frame = star.frame.insetBy(dx: -2, dy: -2)
                star.needsDisplay = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            for star in stars { star.alphaValue = 0.5 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            for star in stars { star.removeFromSuperview() }
            self.isPlayingHitEffect = false
        }
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

// MARK: - HP Bar View (drawn as native NSView to bypass template image tinting)

private class HPBarView: NSView {
    var value: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let v = CGFloat(min(max(value, 0), 1))
        let r = bounds.height / 2

        // Track background
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()

        // Fill — HP style: green=healthy, red=critical
        let color: NSColor
        if v > 0.5 { color = .systemGreen }
        else if v > 0.25 { color = .systemYellow }
        else if v > 0.1 { color = .systemOrange }
        else { color = .systemRed }

        let fillRect = NSRect(x: 0, y: 0, width: bounds.width * v, height: bounds.height)
        color.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()
    }
}

// MARK: - Hit Star Burst

private class HitStarView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cx = bounds.midX
        let cy = bounds.midY
        let outerR = min(bounds.width, bounds.height) / 2
        let innerR = outerR * 0.2  // sharper spikes
        let spikes = 4
        let path = NSBezierPath()

        for i in 0..<(spikes * 2) {
            let angle = CGFloat(i) * .pi / CGFloat(spikes) - .pi / 2
            let r = i.isMultiple(of: 2) ? outerR : innerR
            let x = cx + r * cos(angle)
            let y = cy + r * sin(angle)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.close()

        NSColor.systemRed.setFill()
        path.fill()
        NSColor.systemOrange.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
