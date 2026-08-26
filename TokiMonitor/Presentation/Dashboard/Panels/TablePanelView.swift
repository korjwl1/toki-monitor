import SwiftUI

/// Table panel render.
///
/// Built by hand rather than with SwiftUI's `Table`, for the three things the
/// contract asks of it (R4/R6) and `Table` does not give: a header that can be
/// switched off, per-column alignment and unit formatting, and horizontal
/// scrolling that stays INSIDE the panel. `Table` in a narrow panel truncates
/// its columns and takes its header with it; the page must never gain a
/// sideways scrollbar because one panel was too wide.
///
/// It also carries the one view-time filter a table can have. A table has no
/// legend — there are no series to switch off, only rows — so contract R7's
/// legend toggle leaves it with nothing, and Grafana's answer for a table is a
/// per-column filter instead: the editor marks a field filterable, a funnel
/// appears in that column's header, and a reader uses it without entering edit
/// mode. That is what `excluded` and `onSetFilter` are.
struct TablePanelView: View {
    let panel: PanelConfig
    let data: TimeSeriesData?
    let frames: FrameSet?

    /// Values this reader has excluded, keyed by column. Render stage: the
    /// query is not re-run, the rows are already here, and which of them to
    /// draw is a question about the drawing.
    var excluded: [String: Set<String>] = [:]
    /// Replace one column's exclusions. nil where there is nothing to filter
    /// with — the editor's preview, and the snapshot harness — and then no
    /// funnel is drawn at all, because a control that does nothing is worse
    /// than no control (계약 R1).
    var onSetFilter: ((_ column: String, _ excluded: Set<String>) -> Void)?
    /// Bring every row back. Only the "everything is excluded" note offers it.
    var onClearFilters: (() -> Void)?

    /// Which column's filter popover is open. One at a time: two open funnels
    /// over a table this narrow would cover the rows they are filtering.
    @State private var openColumn: String?

    /// What a column holds. The three are not interchangeable — a name is
    /// scanned, a measure is read digit by digit — so the cell text comes from
    /// here rather than from the row's position in an array.
    enum Kind { case name, tokens, cost }

    /// A column knows its own alignment and unit. Numbers go right so their
    /// digits line up; names go left so they can be scanned. Width is the one
    /// thing it does not know until the panel has been measured.
    struct Column {
        let kind: Kind
        let title: String
        let alignment: Alignment
        /// nil for the name column, which is not a measure.
        let unit: String?
        /// The frame column this table column reads, so an override written
        /// against `cost_usd` can find it.
        let field: Field
        var width: CGFloat = 0
        /// How this column is named in a filter — its field name, which is
        /// stable across renames and re-renders in a way the header text is
        /// not.
        var key: String { field.name }
    }

    /// Measures keep a fixed width so their digits line up column to column;
    /// the name takes whatever is left. Below `minNameWidth` the table stops
    /// shrinking and starts scrolling — inside itself.
    private static let measureWidth: CGFloat = 84
    private static let minNameWidth: CGFloat = 96

    /// The columns without their widths.
    ///
    /// Separated from the measured version so that everything about a column
    /// that is NOT geometry — its field, its unit, the text it puts in a cell —
    /// can be asked outside a `GeometryReader`, which is what lets the filter
    /// and a test read the same answer the drawing does.
    static var specs: [Column] {
        [
            Column(kind: .name, title: L.dash.axisModel, alignment: .leading,
                   unit: nil, field: column("model", .string([]))),
            Column(kind: .tokens, title: L.dash.axisTokens, alignment: .trailing,
                   unit: "tokens", field: column("total_tokens")),
            Column(kind: .cost, title: L.dash.axisCost, alignment: .trailing,
                   unit: "currencyUSD", field: column("cost_usd")),
        ]
    }

    private func columns(nameWidth: CGFloat) -> [Column] {
        Self.specs.map { spec in
            var column = spec
            column.width = spec.kind == .name ? nameWidth : Self.measureWidth
            return column
        }
    }

    /// A stand-in for the frame column this table column sums, carrying its
    /// name and the labels the rows share.
    ///
    /// The table reduces every frame into one row, so by the time a cell is
    /// formatted the field it came from is gone. A matcher needs one to test,
    /// and a name is what `byName`, `byRegex` and `allNumeric` match on — the
    /// three that make sense against a column of a summary table.
    ///
    /// The name column gets one too, typed `.string` so `allNumeric` correctly
    /// passes it by. Without it there is no field for a rule to name, and the
    /// column a reader most wants to filter — the one holding the model names —
    /// would be the one column that could not be marked filterable.
    private static func column(_ name: String,
                               _ values: FieldValues = .number([])) -> Field {
        Field(name: name, values: values)
    }

    // MARK: - What the filter and the drawing both ask

    /// The rows this table draws, after the reader's column filters.
    ///
    /// Static, and the render's own path — `body` calls exactly this — so that
    /// the claim "the filter matches what the cell shows" can be checked
    /// without a window. A filter reimplemented in a test would only prove the
    /// test.
    static func visibleRows(panel: PanelConfig, rows: [PanelDataExtractor.ModelRow],
                            excluded: [String: Set<String>])
        -> [PanelDataExtractor.ModelRow] {
        let columns = specs
        return TableColumnFilters.rows(rows, excluded: excluded) { row, key in
            cellText(row, column: columns.first { $0.key == key }, panel: panel)
        }
    }

    /// Every value one column takes, in the order the rows are sorted.
    ///
    /// Drawn from ALL the rows, not the ones currently getting through — an
    /// excluded value has to stay on the list, or unticking it would be a
    /// one-way door. Other columns' filters are ignored for the same reason: a
    /// value hidden by a filter elsewhere still belongs to this column, and
    /// dropping it from this list would make that filter look like it had
    /// deleted data.
    static func values(of column: Column, panel: PanelConfig,
                       rows: [PanelDataExtractor.ModelRow]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            let value = cellText(row, column: column, panel: panel)
            if seen.insert(value).inserted { out.append(value) }
        }
        return out
    }

    /// Whether a column's header offers a filter. An editor's decision
    /// (Grafana's `custom.filterable`), off unless a rule says otherwise.
    static func isFilterable(_ column: Column, panel: PanelConfig) -> Bool {
        panel.displayConfig(for: column.field).filterable == true
    }

    /// A row's value in one column, exactly as the cell draws it.
    ///
    /// The single place a cell's text is decided, so that the filter's tick
    /// list, the exclusion test and the drawn cell cannot say three different
    /// things about the same number. A nil column — which only a filter keyed
    /// on a column this table no longer has can produce — matches nothing.
    static func cellText(_ row: PanelDataExtractor.ModelRow, column: Column?,
                         panel: PanelConfig) -> String {
        guard let column else { return "" }
        switch column.kind {
        case .name:   return row.model
        case .tokens: return format(Double(row.tokens), column: column, panel: panel)
        case .cost:   return format(row.cost, column: column, panel: panel)
        }
    }

    /// Per-cell formatting.
    ///
    /// The column's own unit is the default; the panel's resolved config for
    /// that column wins over it. Resolved per COLUMN rather than per panel,
    /// which is the whole point of an override here: a table showing tokens and
    /// cost has to be able to say "money" about one column and not the other
    /// (US3, FR-023).
    static func format(_ value: Double, column: Column, panel: PanelConfig) -> String {
        let resolved = panel.displayConfig(for: column.field)
        // Mapping ahead of unit (FR-025). A table is where a sentinel value is
        // most likely to be mistaken for a measurement — a column of numbers
        // with one 0 in it reads as a real zero, and only the mapped word says
        // otherwise.
        return ValueMappings.format(
            value,
            config: FieldDisplayConfig(unit: resolved.unit ?? column.unit,
                                       decimals: resolved.decimals),
            mappings: panel.options.valueMappings
        )
    }

    /// The header, after any `displayName` override written against that
    /// column. A reader who renamed `cost_usd` to "Spend" should see it here
    /// as well as in a legend.
    private func title(_ column: Column) -> String {
        panel.seriesName(column.title, field: column.field)
    }

    /// Whether this column's header draws a funnel: the editor said it may,
    /// and this caller has somewhere to put the answer. The preview and the
    /// snapshot harness pass no handler and get no funnel — a control that
    /// does nothing is worse than no control (계약 R1).
    private func isFilterable(_ column: Column) -> Bool {
        onSetFilter != nil && Self.isFilterable(column, panel: panel)
    }

    var body: some View {
        let all = PanelSeries.rows(panel: panel, frames: frames, data: data)
        GeometryReader { geo in
            // Fit first, scroll second. Fixed column widths meant a panel one
            // grid cell wide showed the model names and hid every number
            // behind a scrollbar — the numbers being the reason for the table.
            let available = geo.size.width - DS.xs * 2
            let nameWidth = max(Self.minNameWidth, available - Self.measureWidth * 2)
            let columns = columns(nameWidth: nameWidth)
            let rows = Self.visibleRows(panel: panel, rows: all, excluded: excluded)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            HStack(spacing: 0) {
                                ForEach(columns.indices, id: \.self) { i in
                                    cell(Self.cellText(row, column: columns[i], panel: panel),
                                         column: columns[i])
                                }
                            }
                            .padding(.vertical, 3)
                            // Zebra striping rather than rules: one fewer line
                            // per row, and the eye still tracks across the width.
                            .background(index.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color.primary.opacity(0.045))
                        }
                        if rows.isEmpty && !all.isEmpty {
                            everythingExcluded(width: max(available, Self.minNameWidth))
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

    /// What the table says when the reader's own filters have left it with
    /// nothing.
    ///
    /// Said here, in the table, rather than by replacing the panel with a
    /// status view — which is what a chart does when every series is hidden.
    /// The difference is where the control lives: a legend goes off screen with
    /// its chart, so that state has to offer a way back, while these funnels
    /// are in the header the table keeps drawing. Replacing the table would
    /// take the only way out with it.
    private func everythingExcluded(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(L.tr("열 필터가 모든 행을 제외했습니다.",
                      "Every row is excluded by a column filter."))
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            if let onClearFilters {
                Button(action: onClearFilters) {
                    Label(L.tr("필터 지우기", "Clear filters"),
                          systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: DS.fontCaption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, DS.sm)
        .frame(width: width, alignment: .leading)
    }

    private func header(_ columns: [Column]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                headerCell(columns[index])
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

    /// One header cell: its name, and the funnel where the column has one.
    ///
    /// The funnel sits on the side the column's values are NOT aligned to, so
    /// it never lands between the header text and the digits underneath it.
    private func headerCell(_ column: Column) -> some View {
        HStack(spacing: 2) {
            if column.alignment == .trailing { Spacer(minLength: 0) }
            if isFilterable(column) { funnel(column) }
            Text(title(column))
                .font(.system(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
            if column.alignment == .leading { Spacer(minLength: 0) }
        }
        .frame(width: column.width, alignment: column.alignment)
        .padding(.horizontal, DS.xs)
    }

    @ViewBuilder
    private func funnel(_ column: Column) -> some View {
        let active = !(excluded[column.key] ?? []).isEmpty
        Button {
            openColumn = openColumn == column.key ? nil : column.key
        } label: {
            // Filled while filtering, outlined while not — the state is a
            // shape, so it survives being read without colour (계약 R6).
            Image(systemName: active
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.72))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reachable by keyboard regardless of the system's full-keyboard-access
        // setting — the same reason the legend's entries are focusable.
        .focusable()
        .help(L.tr("\(title(column)) 열 값 걸러내기",
                   "Filter the \(title(column)) column"))
        .accessibilityLabel(L.tr("\(title(column)) 열 필터",
                                 "Filter \(title(column)) column"))
        .accessibilityValue(filterSummary(column))
        .accessibilityHint(L.tr("이 열에서 보여줄 값을 고릅니다. 질의는 다시 실행되지 않습니다.",
                                "Chooses which values this column shows. The query is not re-run."))
        .popover(isPresented: Binding(
            get: { openColumn == column.key },
            set: { if !$0 && openColumn == column.key { openColumn = nil } }
        ), arrowEdge: .bottom) {
            filterPopover(column)
        }
    }

    /// What assistive technology reads for a funnel: how many of the column's
    /// values are getting through.
    private func filterSummary(_ column: Column) -> String {
        let values = distinctValues(column)
        let out = excluded[column.key] ?? []
        let shown = values.filter { !out.contains($0) }.count
        guard !out.isEmpty else {
            return L.tr("모든 값 표시 중", "Showing every value")
        }
        return L.tr("값 \(values.count)개 중 \(shown)개 표시 중",
                    "Showing \(shown) of \(values.count) values")
    }

    // MARK: - The filter itself

    private func distinctValues(_ column: Column) -> [String] {
        Self.values(of: column, panel: panel,
                    rows: PanelSeries.rows(panel: panel, frames: frames, data: data))
    }

    /// The funnel's popover: one tick per value, plus the two bulk edits.
    ///
    /// Value inclusion and exclusion, and deliberately nothing else. Grafana's
    /// table filter also carries operators — regex, comparisons, boolean
    /// expressions — and every one of them is a second query language sitting
    /// on top of the one the panel already has. This table's numeric columns
    /// are sums over the whole window, so there are as many distinct values as
    /// there are rows and a tick list says everything a comparison would.
    private func filterPopover(_ column: Column) -> some View {
        let values = distinctValues(column)
        let out = excluded[column.key] ?? []
        return VStack(alignment: .leading, spacing: DS.xs) {
            Text(title(column))
                .font(.system(size: DS.fontCaption, weight: .semibold))
                .foregroundStyle(Color.primary)

            HStack(spacing: DS.xs) {
                Button(L.tr("모두", "All")) {
                    onSetFilter?(column.key, [])
                }
                .disabled(out.isEmpty)
                Button(L.tr("모두 해제", "None")) {
                    onSetFilter?(column.key, Set(values))
                }
                .disabled(out.count == values.count)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: DS.fontCaption))

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(values, id: \.self) { value in
                        Toggle(isOn: Binding(
                            get: { !out.contains(value) },
                            set: { shown in
                                var next = out
                                if shown { next.remove(value) } else { next.insert(value) }
                                onSetFilter?(column.key, next)
                            }
                        )) {
                            Text(value)
                                .font(.system(size: DS.fontCaption))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.trailing, DS.xs)
            }
            .frame(maxHeight: 200)
        }
        .padding(DS.sm)
        .frame(width: 190)
    }

    // MARK: - Cells

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

}
