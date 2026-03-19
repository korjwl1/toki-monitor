import AppKit

/// Renders a mini sparkline graph in the menu bar, Stats-style.
/// Filled area with gradient + top stroke line.
@MainActor
struct SparklineRenderer {
    private let width: CGFloat = 38
    private let height: CGFloat = 18

    func update(history: [Double], button: NSStatusBarButton) {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let padding: CGFloat = 1
            let graphRect = rect.insetBy(dx: padding, dy: padding)

            guard history.count >= 2 else {
                // Empty: flat line at bottom
                let path = NSBezierPath()
                path.move(to: NSPoint(x: graphRect.minX, y: graphRect.minY + 1))
                path.line(to: NSPoint(x: graphRect.maxX, y: graphRect.minY + 1))
                NSColor.tertiaryLabelColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }

            let maxValue = max(history.max() ?? 1, 1)
            let stepX = graphRect.width / CGFloat(history.count - 1)

            // Build points
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

            // Gradient fill
            NSGraphicsContext.saveGraphicsState()
            fillPath.setClip()
            let gradient = NSGradient(
                starting: NSColor.labelColor.withAlphaComponent(0.25),
                ending: NSColor.labelColor.withAlphaComponent(0.05)
            )
            gradient?.draw(in: graphRect, angle: 90)
            NSGraphicsContext.restoreGraphicsState()

            // Top stroke line
            let linePath = NSBezierPath()
            linePath.move(to: points[0])
            for point in points.dropFirst() {
                linePath.line(to: point)
            }
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            linePath.lineWidth = 1.0
            linePath.lineCapStyle = .round
            linePath.lineJoinStyle = .round
            linePath.stroke()

            return true
        }

        image.isTemplate = true
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
    }
}
