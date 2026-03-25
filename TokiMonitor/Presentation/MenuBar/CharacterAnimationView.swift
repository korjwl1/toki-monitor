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

    private(set) var isPoisoned = false
    private var poisonTimer: Timer?
    private var poisonBubbles: [PoisonBubbleView] = []
    private weak var poisonTintOverlay: PoisonTintOverlayView?

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
                    // Stop effects while sleeping
                    if isPoisoned { stopPoison() }
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
        hpBarView?.removeFromSuperview()
        hpBarView = nil
        stopPoison()
        isPlayingHitEffect = false
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

        // Sync poison silhouette with current frame
        poisonTintOverlay?.sourceImage = frame

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

    // MARK: - Shake (shared by hit & poison)
    // Uses CAKeyframeAnimation on layer transform — doesn't touch button.image,
    // so it runs independently of the frame animation timer.

    private func shakeCharacter(on button: NSStatusBarButton, amplitude: CGFloat = 3.5, duration: Double = 0.4) {
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, amplitude, -amplitude, amplitude * 0.7,
                        -amplitude * 0.5, amplitude * 0.3, -amplitude * 0.15, 0]
        anim.keyTimes = [0, 0.12, 0.28, 0.42, 0.56, 0.7, 0.85, 1.0]
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        anim.isAdditive = true

        layer.removeAnimation(forKey: "shake")
        layer.add(anim, forKey: "shake")
    }

    // MARK: - Hit Effect

    func playHitEffect(on button: NSStatusBarButton) {
        guard !isPlayingHitEffect, !isSleeping, poisonBubbles.isEmpty else { return }
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
            let rotation = CGFloat.random(in: -0.6...0.6)
            star.frameCenterRotation = rotation * 180 / .pi
            button.addSubview(star)
            stars.append(star)
        }

        shakeCharacter(on: button)

        // Stars scale up then fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard self != nil else { return }
            for star in stars {
                star.frame = star.frame.insetBy(dx: -2, dy: -2)
                star.needsDisplay = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard self != nil else { return }
            for star in stars { star.alphaValue = 0.5 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            for star in stars { star.removeFromSuperview() }
            self?.isPlayingHitEffect = false
        }
    }

    // MARK: - Poison Effect

    func startPoison(on button: NSStatusBarButton) {
        guard !isPoisoned, !isSleeping else { return }
        isPoisoned = true

        // Spawn a batch every 1.5s
        spawnPoisonBatch(on: button)
        poisonTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPoisoned else { return }
                self.spawnPoisonBatch(on: button)
            }
        }
    }

    func stopPoison() {
        isPoisoned = false
        poisonTimer?.invalidate()
        poisonTimer = nil
        for b in poisonBubbles { b.removeFromSuperview() }
        poisonBubbles.removeAll()
        poisonTintOverlay?.sourceImage = nil
        poisonTintOverlay?.removeFromSuperview()
        poisonTintOverlay = nil
    }

    private func spawnPoisonBatch(on button: NSStatusBarButton) {
        let imgRect = button.cell?.imageRect(forBounds: button.bounds)
            ?? button.bounds
        // Shake when bubbles start bursting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.shakeCharacter(on: button, amplitude: 1.2, duration: 0.5)
        }

        // Purple silhouette flash — 2 pulses starting at burst time
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }

            let overlay: PoisonTintOverlayView
            if let existing = self.poisonTintOverlay {
                overlay = existing
            } else {
                overlay = PoisonTintOverlayView(frame: imgRect)
                overlay.alphaValue = 0
                button.addSubview(overlay)
                self.poisonTintOverlay = overlay
            }
            overlay.frame = imgRect

            let pulseDuration = 0.5
            for pulse in 0..<2 {
                let pulseStart = Double(pulse) * pulseDuration
                let steps = 12
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    DispatchQueue.main.asyncAfter(deadline: .now() + pulseStart + t * pulseDuration) { [weak overlay] in
                        let blend = t < 0.5 ? t * 2 : (1 - t) * 2
                        overlay?.alphaValue = CGFloat(blend * 0.55)
                    }
                }
            }
        }

        let count = Int.random(in: 2...3)

        let centerX = imgRect.midX
        let centerY = imgRect.midY
        let radiusX = imgRect.width * 0.35
        let radiusY = imgRect.height * 0.35
        var placedCenters: [CGPoint] = []

        for _ in 0..<count {
            let size: CGFloat = CGFloat.random(in: 3...5)

            // Random point inside ellipse, with minimum spacing
            var x: CGFloat = 0
            var y: CGFloat = 0
            for _ in 0..<20 {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let r = sqrt(CGFloat.random(in: 0...1))  // uniform distribution inside circle
                let px = centerX + r * radiusX * cos(angle)
                let py = centerY + r * radiusY * sin(angle)
                let tooClose = placedCenters.contains { abs($0.x - px) < 4 && abs($0.y - py) < 4 }
                if !tooClose {
                    x = px - size / 2
                    y = py - size / 2
                    placedCenters.append(CGPoint(x: px, y: py))
                    break
                }
                x = px - size / 2
                y = py - size / 2
            }

            let dot = PoisonBubbleView(frame: NSRect(x: x, y: y, width: size, height: size))
            dot.alphaValue = 0
            button.addSubview(dot)
            poisonBubbles.append(dot)

            let cx = x + size / 2
            let cy = y + size / 2
            let lifetime = Double.random(in: 0.8...1.2)
            let steps = 24
            let stepTime = lifetime / Double(steps)

            for i in 0...steps {
                let t = Double(i) / Double(steps)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * stepTime) { [weak dot] in
                    guard let dot else { return }

                    if t < 0.3 {
                        // Phase 1: appear and grow
                        let scale = CGFloat(t / 0.3)
                        let s = size * scale
                        dot.frame = NSRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
                        dot.alphaValue = CGFloat(t / 0.3)
                    } else if t < 0.6 {
                        // Phase 2: hold + slight wobble
                        let wobble = sin(CGFloat(t) * 6 * .pi) * 0.5
                        dot.frame = NSRect(x: cx - size / 2 + wobble, y: cy - size / 2, width: size, height: size)
                        dot.alphaValue = 1.0
                    } else {
                        // Phase 3: burst — expand rapidly and fade
                        let burstT = CGFloat((t - 0.6) / 0.4)
                        let burstSize = size * (1.0 + burstT * 1.5)
                        dot.frame = NSRect(x: cx - burstSize / 2, y: cy - burstSize / 2,
                                           width: burstSize, height: burstSize)
                        dot.alphaValue = 1.0 - burstT
                    }
                    dot.needsDisplay = true
                }
            }

            // Cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 0.1) { [weak self, weak dot] in
                dot?.removeFromSuperview()
                if let dot {
                    self?.poisonBubbles.removeAll { $0 === dot }
                }
                // Prune any zombie entries (deallocated views)
                self?.poisonBubbles.removeAll { $0.superview == nil }
            }
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

// MARK: - Poison Bubble

private class PoisonBubbleView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Pokemon-style poison purple: deep magenta-purple
        NSColor(calibratedRed: 0.55, green: 0.1, blue: 0.6, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Poison Silhouette Overlay
// Draws the character image as a solid purple silhouette (sourceAtop).
// Only character pixels are affected — transparent areas stay transparent.
// Animate alphaValue for smooth color gradient effect.

private class PoisonTintOverlayView: NSView {
    var sourceImage: NSImage? { didSet { needsDisplay = true } }
    private let overlayColor = NSColor(calibratedRed: 0.55, green: 0.1, blue: 0.6, alpha: 1.0)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let src = sourceImage else { return }
        // Draw character then fill only character pixels with purple
        src.draw(in: bounds)
        overlayColor.set()
        bounds.fill(using: .sourceAtop)
    }
}
