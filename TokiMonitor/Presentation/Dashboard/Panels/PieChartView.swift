import SwiftUI
import Charts

/// Interactive donut chart with fixed chart size, truncated legend, and hover tooltip.
struct PieChartView: View {
    struct Entry: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
    }

    let entries: [Entry]
    let colors: [Color]?

    private static let maxLegendItems = 8
    private static let minPercent = 2.0  // below this → "Others"
    private static let defaultPalette: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal, .indigo, .mint, .pink, .brown
    ]

    @State private var hoveredLabel: String?

    private var total: Double { entries.reduce(0) { $0 + $1.value } }

    private var displayEntries: [Entry] {
        let sorted = entries.sorted { $0.value > $1.value }
        let total = sorted.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return sorted }

        // Keep items above threshold AND within max count
        var top: [Entry] = []
        var rest: [Entry] = []
        for entry in sorted {
            let pct = entry.value / total * 100
            if top.count < Self.maxLegendItems - 1 && pct >= Self.minPercent {
                top.append(entry)
            } else {
                rest.append(entry)
            }
        }

        if rest.isEmpty { return top }
        let otherValue = rest.reduce(0.0) { $0 + $1.value }
        return top + [Entry(label: L.tr("기타", "Others"), value: otherValue)]
    }

    private func color(for index: Int) -> Color {
        if let colors, index < colors.count { return colors[index] }
        return Self.defaultPalette[index % Self.defaultPalette.count]
    }

    private func colorMap() -> [String: Color] {
        var map: [String: Color] = [:]
        for (i, entry) in displayEntries.enumerated() {
            map[entry.label] = color(for: i)
        }
        return map
    }

    var body: some View {
        HStack(spacing: 12) {
            chartView
                .frame(minWidth: 120, minHeight: 120)
                .frame(maxWidth: 200, maxHeight: 200)
                .aspectRatio(1, contentMode: .fit)

            legendView
                .frame(maxWidth: 140)
        }
        .frame(minHeight: 150)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chart

    private var chartView: some View {
        let cmap = colorMap()
        return ZStack {
            Chart(displayEntries) { entry in
                SectorMark(
                    angle: .value("value", entry.value),
                    innerRadius: .ratio(hoveredLabel == entry.label ? 0.45 : 0.5),
                    outerRadius: .ratio(hoveredLabel == entry.label ? 1.0 : 0.92),
                    angularInset: 1
                )
                .foregroundStyle(cmap[entry.label] ?? .gray)
                .cornerRadius(3)
                .opacity(hoveredLabel == nil || hoveredLabel == entry.label ? 1.0 : 0.4)
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            withAnimation(.easeOut(duration: 0.2)) {
                                switch phase {
                                case .active(let location):
                                    hoveredLabel = findEntry(at: location, in: geo.size)
                                case .ended:
                                    hoveredLabel = nil
                                }
                            }
                        }
                }
            }

            // Center tooltip
            if let label = hoveredLabel, let entry = displayEntries.first(where: { $0.label == label }) {
                VStack(spacing: 2) {
                    Text(entry.label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(percentage(entry.value))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.primary)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Legend

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(displayEntries.enumerated()), id: \.element.id) { i, entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: i))
                        .frame(width: 8, height: 8)
                    Text(entry.label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(
                            hoveredLabel == nil || hoveredLabel == entry.label
                            ? .primary : .tertiary
                        )
                }
                .onHover { isHovered in
                    withAnimation(.easeOut(duration: 0.2)) {
                        hoveredLabel = isHovered ? entry.label : nil
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func percentage(_ value: Double) -> String {
        guard total > 0 else { return "0%" }
        let pct = value / total * 100
        if pct >= 10 { return "\(Int(pct))%" }
        return String(format: "%.1f%%", pct)
    }

    private func findEntry(at location: CGPoint, in size: CGSize) -> String? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let radius = min(size.width, size.height) / 2

        // Check if within donut ring
        guard distance > radius * 0.45 && distance < radius else { return nil }

        // Calculate angle (0 = top, clockwise)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }

        // Map angle to entry
        var accumulated = 0.0
        for entry in displayEntries {
            accumulated += entry.value
            let entryAngle = (accumulated / total) * 2 * .pi
            if angle <= entryAngle { return entry.label }
        }
        return displayEntries.last?.label
    }
}
