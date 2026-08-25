import SwiftUI

/// Table panel render.
///
/// Built by hand rather than with SwiftUI's `Table`, for the three things the
/// contract asks of it (R4/R6) and `Table` does not give: a header that can be
/// switched off, per-column alignment and unit formatting, and horizontal
/// scrolling that stays INSIDE the panel. `Table` in a narrow panel truncates
/// its columns and takes its header with it; the page must never gain a
/// sideways scrollbar because one panel was too wide.
struct TablePanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?

    /// A column knows its own width, alignment and unit. Numbers go right so
    /// their digits line up; names go left so they can be scanned.
    private struct Column {
        let title: String
        let width: CGFloat
        let alignment: Alignment
        /// nil for the name column, which is not a measure.
        let unit: String?
    }

    /// Measures keep a fixed width so their digits line up column to column;
    /// the name takes whatever is left. Below `minNameWidth` the table stops
    /// shrinking and starts scrolling — inside itself.
    private static let measureWidth: CGFloat = 84
    private static let minNameWidth: CGFloat = 96

    private func columns(nameWidth: CGFloat) -> [Column] {
        [
            Column(title: L.dash.axisModel, width: nameWidth, alignment: .leading, unit: nil),
            Column(title: L.dash.axisTokens, width: Self.measureWidth,
                   alignment: .trailing, unit: "tokens"),
            Column(title: L.dash.axisCost, width: Self.measureWidth,
                   alignment: .trailing, unit: "currencyUSD"),
        ]
    }

    var body: some View {
        let rows = PanelSeries.rows(frames: frames, data: data)
        GeometryReader { geo in
            // Fit first, scroll second. Fixed column widths meant a panel one
            // grid cell wide showed the model names and hid every number
            // behind a scrollbar — the numbers being the reason for the table.
            let available = geo.size.width - DS.xs * 2
            let nameWidth = max(Self.minNameWidth, available - Self.measureWidth * 2)
            let columns = columns(nameWidth: nameWidth)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 0) {
                                cell(row.model, column: columns[0])
                                cell(format(Double(row.tokens), column: columns[1]), column: columns[1])
                                cell(format(row.cost, column: columns[2]), column: columns[2])
                            }
                            .padding(.vertical, 3)
                            // Zebra striping rather than rules: one fewer line
                            // per row, and the eye still tracks across the width.
                            .background(index.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color.primary.opacity(0.045))
                        }
                    } header: {
                        if panel.options.showHeader { header(columns) }
                    }
                }
                .padding(.horizontal, DS.xs)
            }
            // Clip to the panel. This is the line that keeps a wide table from
            // pushing the dashboard itself sideways.
            .clipped()
        }
    }

    private func header(_ columns: [Column]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                Text(columns[index].title)
                    .font(.system(size: DS.fontCaption, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: columns[index].width, alignment: columns[index].alignment)
                    .padding(.horizontal, DS.xs)
            }
        }
        .padding(.vertical, DS.xs)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 0.5)
        }
    }

    private func cell(_ text: String, column: Column) -> some View {
        Text(text)
            .font(.system(size: DS.fontCaption,
                          design: column.unit == nil ? .default : .monospaced))
            .foregroundStyle(Color.primary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: column.width, alignment: column.alignment)
            .padding(.horizontal, DS.xs)
    }

    /// Per-cell formatting. The column's own unit is the default; a unit set on
    /// the panel overrides it, because a reader who typed one into the editor
    /// expects to see it (contract R1).
    private func format(_ value: Double, column: Column) -> String {
        FieldFormatter.format(
            value,
            config: FieldDisplayConfig(unit: panel.options.unit ?? column.unit,
                                       decimals: panel.options.decimals)
        )
    }
}
