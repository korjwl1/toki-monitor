import AppKit

/// Describes an animation theme loaded from a bundle directory.
/// Each theme folder contains a `theme.json` and numbered frame PNGs.
struct AnimationThemeConfig: Codable {
    let id: String
    let name: String
    var nameKo: String? = nil
    let frameSize: [CGFloat]   // [width, height]
    let canvasSize: [CGFloat]  // [width, height]
    var hpBar: HPBarConfig? = nil
    let sleep: SleepConfig

    struct HPBarConfig: Codable {
        /// Bar width as ratio of character width (0.0–1.0, default 0.7)
        var widthRatio: CGFloat? = nil
        /// Bar height in pt (default 2)
        var height: CGFloat? = nil
        /// Y offset from top of button (default 1)
        var yOffset: CGFloat? = nil
        /// X offset from calculated center (default 0)
        var xOffset: CGFloat? = nil
    }

    struct SleepConfig: Codable {
        /// "overlay" = auto-generate zZ frames, "frames" = use sleep_XX.png files
        let mode: String
        /// Offset from top-right of character for zZ text (overlay mode)
        var textOffset: [CGFloat]?
        /// Font size for zZ text (overlay mode)
        var fontSize: CGFloat?
        /// Frame interval for sleep animation
        var interval: TimeInterval?
    }

    @MainActor var localizedName: String {
        if let ko = nameKo { return L.tr(ko, name) }
        return name
    }
    var hpBarWidthRatio: CGFloat { hpBar?.widthRatio ?? 0.7 }
    var hpBarHeight: CGFloat { hpBar?.height ?? 2 }
    var hpBarYOffset: CGFloat { hpBar?.yOffset ?? 1 }
    var hpBarXOffset: CGFloat { hpBar?.xOffset ?? 0 }
    var frameSizeNS: NSSize { NSSize(width: frameSize[0], height: frameSize[1]) }
    var canvasSizeNS: NSSize { NSSize(width: canvasSize[0], height: canvasSize[1]) }
    var sleepInterval: TimeInterval { sleep.interval ?? 0.8 }
    var sleepFontSize: CGFloat { sleep.fontSize ?? 5 }
    var sleepTextOffsetX: CGFloat { sleep.textOffset?[0] ?? -7 }
    var sleepTextOffsetY: CGFloat { sleep.textOffset?[1] ?? -1 }
}

/// A fully loaded animation theme with ready-to-use frames.
@MainActor
struct AnimationTheme {
    let config: AnimationThemeConfig
    let runFrames: [NSImage]
    let sleepFrames: [NSImage]

    /// Load a theme from a bundle directory path.
    static func load(from directory: URL) -> AnimationTheme? {
        let jsonURL = directory.appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let config = try? JSONDecoder().decode(AnimationThemeConfig.self, from: data)
        else { return nil }

        let runFrames = loadNumberedFrames(
            prefix: "run",
            in: directory,
            frameSize: config.frameSizeNS,
            canvasSize: config.canvasSizeNS
        )

        guard !runFrames.isEmpty else { return nil }

        let sleepFrames: [NSImage]
        if config.sleep.mode == "frames" {
            sleepFrames = loadNumberedFrames(
                prefix: "sleep",
                in: directory,
                frameSize: config.frameSizeNS,
                canvasSize: config.canvasSizeNS
            )
        } else {
            sleepFrames = generateOverlaySleepFrames(
                base: runFrames[0],
                config: config
            )
        }

        return AnimationTheme(config: config, runFrames: runFrames, sleepFrames: sleepFrames)
    }

    /// Discover all themes in the Animations resource directory.
    static func discoverAll() -> [AnimationTheme] {
        guard let animDir = Bundle.main.resourceURL?.appendingPathComponent("Animations") else {
            return []
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: animDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { load(from: $0) }
    }

    // MARK: - Private

    private static func loadNumberedFrames(
        prefix: String,
        in directory: URL,
        frameSize: NSSize,
        canvasSize: NSSize
    ) -> [NSImage] {
        var frames: [NSImage] = []
        for i in 0..<100 {
            let name = String(format: "%@_%02d.png", prefix, i)
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let src = NSImage(contentsOf: url) else { break }
            src.size = frameSize
            let canvas = NSImage(size: canvasSize, flipped: false) { _ in
                src.draw(in: NSRect(origin: .zero, size: frameSize))
                return true
            }
            canvas.isTemplate = true
            frames.append(canvas)
        }
        return frames
    }

    static func generateOverlaySleepFrames(
        base: NSImage,
        config: AnimationThemeConfig
    ) -> [NSImage] {
        let zTexts = ["", "z", "zZ"]
        let canvasSize = config.canvasSizeNS
        let rabbitRect = NSRect(origin: .zero, size: base.size)

        return zTexts.map { zText in
            let image = NSImage(size: canvasSize, flipped: false) { rect in
                base.draw(in: rabbitRect)
                if !zText.isEmpty {
                    let font = NSFont.systemFont(ofSize: config.sleepFontSize, weight: .bold)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                    let attrStr = NSAttributedString(string: zText, attributes: attrs)
                    let textSize = attrStr.size()
                    let textX = rabbitRect.maxX + config.sleepTextOffsetX
                    let textY = rect.maxY - textSize.height + config.sleepTextOffsetY
                    attrStr.draw(at: NSPoint(x: textX, y: textY))
                }
                return true
            }
            image.isTemplate = true
            return image
        }
    }
}
