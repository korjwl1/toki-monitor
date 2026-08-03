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
    private var lastUpdateTime: Date = Date()
    private var updateWatchdogTimer: Timer?

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
        lastUpdateTime = Date()

        // Watchdog: if update() isn't called for 5 seconds, force idle (e.g. daemon disconnected)
        updateWatchdogTimer?.invalidate()
        updateWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.stopAnimation()
                self.applyFrame(0, from: self.frames, to: button)
                self.idleSince = self.idleSince ?? Date()
                // The watchdog fires precisely when update() stopped being
                // called — if it doesn't arm the sleep transition itself,
                // nothing else will, and the character stays awake-idle
                // forever (observed in the field: idle but never sleeping).
                self.scheduleSleepCheck(button: button)
            }
        }

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
        updateWatchdogTimer?.invalidate()
        updateWatchdogTimer = nil
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

        // Ultimate fallback: placeholder circles
        if theme == nil {
            let placeholderConfig = AnimationThemeConfig(
                id: "placeholder", name: "Placeholder",
                frameSize: [18, 18], canvasSize: [18, 18],
                sleep: .init(mode: "overlay")
            )
            theme = AnimationTheme(
                config: placeholderConfig,
                runFrames: generatePlaceholderFrames(),
                sleepFrames: []
            )
        }
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

    private var animationGeneration: UInt64 = 0

    private func startAnimation(interval: TimeInterval, button: NSStatusBarButton) {
        frameTimer?.invalidate()
        currentInterval = interval
        animationGeneration &+= 1
        let gen = animationGeneration

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Ignore if animation was stopped/restarted since this timer was created
                guard self.animationGeneration == gen else { return }
                self.advanceFrame(button: button)
            }
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
        animationGeneration &+= 1  // invalidate any pending advanceFrame dispatches
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

        // Purple silhouette flash — 2 pulses starting at burst time.
        // One Core Animation keyframe on the layer's opacity replaces the old
        // per-step asyncAfter loop (was ~26 main-queue closures per batch).
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

            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.0, 0.55, 0.0, 0.55, 0.0]
            pulse.keyTimes = [0.0, 0.25, 0.5, 0.75, 1.0]
            pulse.duration = 1.0
            pulse.calculationMode = .linear
            overlay.alphaValue = 0
            overlay.layer?.add(pulse, forKey: "poisonPulse")
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
            var cx = centerX
            var cy = centerY
            for _ in 0..<20 {
                let angle = CGFloat.random(in: 0...(2 * .pi))
                let r = sqrt(CGFloat.random(in: 0...1))  // uniform distribution inside circle
                let px = centerX + r * radiusX * cos(angle)
                let py = centerY + r * radiusY * sin(angle)
                cx = px
                cy = py
                let tooClose = placedCenters.contains { abs($0.x - px) < 4 && abs($0.y - py) < 4 }
                if !tooClose {
                    placedCenters.append(CGPoint(x: px, y: py))
                    break
                }
            }

            let dot = PoisonBubbleView(frame: NSRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size))
            dot.alphaValue = 0
            button.addSubview(dot)
            poisonBubbles.append(dot)

            let lifetime = Double.random(in: 0.8...1.2)
            animatePoisonBubble(dot, size: size, cx: cx, cy: cy, lifetime: lifetime)
        }
    }

    /// Drives one poison bubble's grow → hold → burst lifecycle with AppKit
    /// animations instead of ~25 per-frame asyncAfter closures. Core Animation
    /// interpolates each phase on the render server, so we only schedule a few
    /// main-queue closures (the phase transitions and cleanup) per bubble.
    private func animatePoisonBubble(_ dot: PoisonBubbleView, size: CGFloat, cx: CGFloat, cy: CGFloat, lifetime: Double) {
        func frame(_ s: CGFloat) -> NSRect {
            NSRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
        }

        let grow = lifetime * 0.3
        let hold = lifetime * 0.3
        let burst = lifetime * 0.4

        dot.frame = frame(size * 0.01)
        dot.alphaValue = 0

        // Phase 1: appear and grow to full size.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = grow
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dot.animator().frame = frame(size)
            dot.animator().alphaValue = 1
        }, completionHandler: { [weak self, weak dot] in
            // Phase 2: brief hold, then Phase 3: burst outward and fade.
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self, weak dot] in
                guard let dot else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = burst
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    dot.animator().frame = frame(size * 2.5)
                    dot.animator().alphaValue = 0
                }, completionHandler: { [weak self, weak dot] in
                    dot?.removeFromSuperview()
                    if let dot { self?.poisonBubbles.removeAll { $0 === dot } }
                    // Prune any zombie entries (deallocated views)
                    self?.poisonBubbles.removeAll { $0.superview == nil }
                })
            }
        })
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
