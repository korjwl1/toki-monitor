import AppKit

/// Renders a mini sparkline graph in the menu bar, Stats-style.
@MainActor
struct SparklineRenderer {
    private let width: CGFloat = 32
    private let height: CGFloat = 14

    func update(history: [Double], button: NSStatusBarButton, tintColor: NSColor? = nil) {
        let drawColor = tintColor ?? NSColor.labelColor
        let isTemplate = tintColor == nil

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let graphRect = rect

            guard history.count >= 2 else {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: graphRect.minX, y: graphRect.minY + 1))
                path.line(to: NSPoint(x: graphRect.maxX, y: graphRect.minY + 1))
                (isTemplate ? NSColor.tertiaryLabelColor : drawColor.withAlphaComponent(0.3)).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }

            let maxValue = max(history.max() ?? 1, 1)
            let stepX = graphRect.width / CGFloat(history.count - 1)

            let points = history.enumerated().map { i, value in
                NSPoint(
                    x: graphRect.minX + CGFloat(i) * stepX,
                    y: graphRect.minY + CGFloat(value / maxValue) * graphRect.height
                )
            }

            // Filled area (gradient)
            let fillPath = NSBezierPath()
            fillPath.move(to: NSPoint(x: points.first!.x, y: graphRect.minY))
            for point in points {
                fillPath.line(to: point)
            }
            fillPath.line(to: NSPoint(x: points.last!.x, y: graphRect.minY))
            fillPath.close()

            NSGraphicsContext.saveGraphicsState()
            fillPath.setClip()
            let gradient = NSGradient(
                starting: drawColor.withAlphaComponent(0.25),
                ending: drawColor.withAlphaComponent(0.05)
            )
            gradient?.draw(in: graphRect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()

            // Top stroke line
            let linePath = NSBezierPath()
            linePath.move(to: points[0])
            for point in points.dropFirst() {
                linePath.line(to: point)
            }
            drawColor.withAlphaComponent(0.8).setStroke()
            linePath.lineWidth = 1.0
            linePath.lineCapStyle = .round
            linePath.lineJoinStyle = .round
            linePath.stroke()

            return true
        }

        image.isTemplate = isTemplate
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
    }
}
