import SwiftUI

/// The legend — and the one way to hide a series (contract R7).
///
/// Swift Charts' own `.chartLegend` draws a legend and nothing more: it cannot
/// be clicked, so the app grew a second control in the toolbar to do the
/// hiding, at dashboard scope, unaware of anything else that filtered. This
/// replaces both. Clicking an entry hides that series **in this panel** and
/// re-runs nothing: the data is already here, and hiding is a decision about
/// what to draw from it.
///
/// It takes no view model. Everything it needs is an entry list, the hidden
/// set, and somewhere to send a click — which keeps it renderable in a test
/// without constructing a `DashboardViewModel` (see `PanelSnapshotHarness` for
/// why that matters).
struct PanelLegendView: View {

    struct Entry: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let color: Color
    }

    let entries: [Entry]
    /// Names currently hidden. A hidden series stays in the legend — it is the
    /// only way back.
    let hidden: Set<String>
    let position: PanelDisplayOptions.LegendPosition
    /// What to do when an entry is clicked, or nil where there is nothing to
    /// toggle.
    ///
    /// A state timeline's legend names STATES, not series: hiding "above 80%"
    /// would not remove a row, it would silently redraw the spans as something
    /// else. Those entries are read-only, and a control that visibly does
    /// nothing is worse than no control — so with no handler the entries are
    /// labels rather than buttons.
    var onToggle: ((String) -> Void)?

    var body: some View {
        if position == .right {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.xs) {
                    ForEach(entries) { entry in
                        item(entry)
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.sm) {
                    ForEach(entries) { entry in
                        item(entry)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder
    private func item(_ entry: Entry) -> some View {
        let isHidden = hidden.contains(entry.name)
        if let onToggle {
            Button { onToggle(entry.name) } label: { row(entry, isHidden: isHidden) }
                .buttonStyle(.plain)
                .modifier(LegendInteraction(name: entry.name, isHidden: isHidden))
        } else {
            row(entry, isHidden: isHidden)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(entry.name)
        }
    }

    private func row(_ entry: Entry, isHidden: Bool) -> some View {
        HStack(spacing: 4) {
            swatch(entry.color, isHidden: isHidden)
            Text(entry.name)
                .font(.system(size: DS.fontTiny))
                // Hidden is marked by a struck-through name and a hollow
                // swatch rather than by fading the row out. Fading is the
                // obvious choice and the wrong one: it puts the legend
                // under the 3:1 the contract asks of it (R6), and the
                // entry a reader most needs to find is the one they just
                // switched off.
                .strikethrough(isHidden)
                .foregroundStyle(isHidden ? DS.iconSecondary : Color.primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// The keyboard and assistive-technology surface of a togglable entry.
private struct LegendInteraction: ViewModifier {
    let name: String
    let isHidden: Bool

    func body(content: Content) -> some View {
        content
        // Reachable by keyboard regardless of the system's full-keyboard-access
        // setting, so the only way to hide a series is not mouse-only.
        .focusable()
        .help(isHidden
              ? L.tr("\(name) 계열을 다시 표시합니다", "Show the \(name) series again")
              : L.tr("\(name) 계열을 숨깁니다", "Hide the \(name) series"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(isHidden ? L.tr("숨김", "Hidden") : L.tr("표시됨", "Shown"))
        .accessibilityHint(L.tr("이 계열의 표시를 전환합니다. 질의는 다시 실행되지 않습니다.",
                                "Toggles this series. The query is not re-run."))
        .accessibilityAddTraits(isHidden ? [] : [.isSelected])
    }
}

extension PanelLegendView {
    /// Filled while shown, hollow while hidden — so the state is legible
    /// without colour and without reading the strikethrough.
    @ViewBuilder
    private func swatch(_ color: Color, isHidden: Bool) -> some View {
        if isHidden {
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }
}
