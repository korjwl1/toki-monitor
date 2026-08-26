import SwiftUI
import Charts

/// Interactive donut chart with a clickable legend and a hover tooltip.
///
/// The legend is `PanelLegendView`, the same one the time series and the bar
/// chart use, for the reason contract R7 gives: hiding a series is the
/// legend's job and the legend's ONLY job, so there is one implementation of
/// it and one place the hidden set lives (`SeriesVisibility`). The pie used to
/// draw a legend of its own that could be hovered and not clicked, which meant
/// this panel type had no way at all to narrow what it showed once the toolbar
/// filter was removed.
struct PieChartView: View {
    struct Entry: Identifiable, Equatable {
        /// The label IS the identity. It used to be a fresh `UUID()`, which is
        /// recomputed on every render — so `ForEach` and the chart's own marks
        /// saw a completely new set of rows each pass and could not animate
        /// between them.
        var id: String { label }
        let label: String
        let value: Double
    }

    let entries: [Entry]
    let colors: [Color]?
    /// Slices the reader switched off in the legend. Render stage: the query
    /// is not re-run, the hidden slice is dropped from the drawing, and what
    /// is left re-proportions to fill the circle.
    var hidden: Set<String> = []
    /// nil where there is nothing to toggle — the editor's preview, and the
    /// snapshot harness. With no handler the legend is labels, not buttons.
    var onToggle: ((String) -> Void)?

    private static let maxLegendItems = 8
    private static let minPercent = 2.0  // below this → "Others"
    private static let defaultPalette: [Color] = DS.categorical

    /// The tail bucket's name. Not a series: it is the name of whatever did
    /// not fit, and hiding it hides that whole tail at once.
    static var othersLabel: String { L.tr("기타", "Others") }

    @State private var hoveredLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationProgress: Double = 0

    // MARK: - Slices

    /// The slices as the legend lists them: the biggest few, with everything
    /// too small to read collapsed into one "Others" entry.
    ///
    /// Static so that the dashboard can ask the same question the drawing
    /// answers — "is anything left once the hidden set is applied" — without
    /// rendering a chart, and so a test can pin the bucketing directly.
    static func bucketed(_ entries: [Entry]) -> [Entry] {
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
        return top + [Entry(label: othersLabel, value: otherValue)]
    }

    /// What is drawn, after the reader's hidden set.
    ///
    /// Applied AFTER the bucketing, not before, and that ordering is the whole
    /// of how hiding interacts with "Others". Hiding a named slice re-proportions
    /// what is left; it never promotes a member of the tail into a slice of its
    /// own, so the legend a reader is clicking through does not rearrange itself
    /// under them. "Others" is one entry like any other and can be switched off
    /// too — which hides the tail as a unit, because that is the only thing the
    /// tail is.
    static func visible(_ bucketed: [Entry], hidden: Set<String>) -> [Entry] {
        hidden.isEmpty ? bucketed : bucketed.filter { !hidden.contains($0.label) }
    }

    private var bucketed: [Entry] { Self.bucketed(entries) }

    private var displayEntries: [Entry] { Self.visible(bucketed, hidden: hidden) }

    /// The shares are of what is still shown. A pie of proportions that kept
    /// the hidden slice in its denominator would draw wedges that no longer
    /// close the circle.
    private var total: Double { displayEntries.reduce(0) { $0 + $1.value } }

    // MARK: - Colour

    private func color(for index: Int) -> Color {
        if let colors, index < colors.count { return colors[index] }
        return Self.defaultPalette[index % Self.defaultPalette.count]
    }

    /// Colours are assigned over the FULL bucketed list, so hiding a slice does
    /// not shift every colour after it along by one — the wedge a reader is
    /// comparing has to stay the colour it was.
    private func colorMap() -> [String: Color] {
        var map: [String: Color] = [:]
        for (i, entry) in bucketed.enumerated() {
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
        .onAppear { sweepIn() }
        .onChange(of: entries.map(\.value)) { _, _ in sweepIn() }
        // Same as the bar chart: switching a series off redraws from the data
        // already here, and the redraw gets the panel's own motion rather than
        // snapping.
        .onChange(of: hidden) { _, _ in sweepIn() }
    }

    /// The sweep that draws the pie in. Under Reduce Motion the slices are at
    /// full size immediately — a wedge growing round the circle is exactly the
    /// motion the setting is asking to be spared (FR-064).
    private func sweepIn() {
        guard Motion.growsFromZero(reduceMotion) else {
            animationProgress = 1
            return
        }
        animationProgress = 0
        withAnimation(.easeOut(duration: 0.4)) {
            animationProgress = 1
        }
    }

    // MARK: - Chart

    private var chartView: some View {
        let cmap = colorMap()
        let slices = displayEntries
        return ZStack {
            Chart(slices) { entry in
                SectorMark(
                    angle: .value("value", entry.value * animationProgress),
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
                            withAnimation(Motion.reveal(reduceMotion)) {
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
            if let label = hoveredLabel, let entry = slices.first(where: { $0.label == label }) {
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

    /// Every bucketed slice, hidden ones included — a hidden entry is the only
    /// way back to the slice it switched off.
    private var legendView: some View {
        let cmap = colorMap()
        return PanelLegendView(
            entries: bucketed.map { .init(name: $0.label, color: cmap[$0.label] ?? .gray) },
            hidden: hidden,
            position: .right,
            onToggle: onToggle,
            // Pointing at a name lifts its wedge and names it in the middle of
            // the donut. This is the only text a slice has.
            onHover: { name in
                withAnimation(Motion.reveal(reduceMotion)) { hoveredLabel = name }
            }
        )
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
        let slices = displayEntries
        let total = self.total
        guard total > 0 else { return nil }
        var accumulated = 0.0
        for entry in slices {
            accumulated += entry.value
            let entryAngle = (accumulated / total) * 2 * .pi
            if angle <= entryAngle { return entry.label }
        }
        return slices.last?.label
    }
}
