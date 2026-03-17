import AppKit

/// Renders a mini sparkline graph in the menu bar button.
@MainActor
struct SparklineRenderer {
    private let width: CGFloat = 32
    private let height: CGFloat = 18

    func update(history: [Double], button: NSStatusBarButton) {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            guard !history.isEmpty else {
                // Draw flat line for empty state
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: rect.midY))
                path.line(to: NSPoint(x: rect.width, y: rect.midY))
                NSColor.tertiaryLabelColor.setStroke()
                path.lineWidth = 1
                path.stroke()
                return true
            }

            let maxValue = max(history.max() ?? 1, 1)
            let points = history.enumerated().map { index, value in
                NSPoint(
                    x: CGFloat(index) / CGFloat(max(history.count - 1, 1)) * rect.width,
                    y: CGFloat(value / maxValue) * (rect.height - 4) + 2
                )
            }

            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.line(to: point)
            }

            NSColor.labelColor.setStroke()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

            return true
        }

        image.isTemplate = true
        button.attributedTitle = NSAttributedString(string: "")
        button.image = image
    }
}
