import SwiftUI

/// What a panel draws when it has no result to draw — idle, loading from
/// nothing, empty, or failed.
///
/// One view for all four so the four cannot drift into looking alike. What
/// makes them distinguishable is deliberately redundant (Mayer's redundancy
/// works in the reader's favour here because the panel may be 120pt tall and
/// only one channel survives): a different symbol, a different title, and —
/// for failure alone — a retry.
///
/// Sizing: a panel can be a single grid cell. `ViewThatFits` drops the detail
/// sentence and then the symbol as the box shrinks, rather than clipping the
/// title or forcing the page to scroll sideways (contract R6).
struct PanelStatusView: View {
    let state: PanelState
    var onRetry: (() -> Void)?
    /// Brings every hidden series back. Only `.empty(.allSeriesHidden)` shows
    /// it, and only that state can be got out of any other way.
    var onShowAllSeries: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .vertical) {
            full
            medium
            minimal
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.accessibilityDescription)
    }

    // MARK: - Layouts

    private var full: some View {
        VStack(spacing: DS.sm) {
            symbol(size: 22)
            title
            if let detail = state.detail {
                Text(detail)
                    .font(.system(size: 11))
                    // `.secondary` is a half-alpha label colour: on the panel's
                    // material it lands near 3:1, which is fine for a chart axis
                    // and not fine for a sentence someone has to read.
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
    }

    private var medium: some View {
        VStack(spacing: DS.xs) {
            symbol(size: 16)
            title
            actions
        }
    }

    private var minimal: some View {
        HStack(spacing: DS.xs) {
            symbol(size: 11)
            title
        }
    }

    // MARK: - Parts

    @ViewBuilder
    private func symbol(size: CGFloat) -> some View {
        if case .loading = state {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(size < 16 ? 0.7 : 1.0)
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(symbolTint)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var title: some View {
        Text(state.title)
            .font(.system(size: DS.fontBody, weight: .semibold))
            .foregroundStyle(Color.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        if state.offersRetry, let onRetry {
            Button(action: onRetry) {
                Label(L.tr("다시 시도", "Retry"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if state.offersShowAllSeries, let onShowAllSeries {
            Button(action: onShowAllSeries) {
                Label(L.tr("모든 계열 표시", "Show all series"), systemImage: "eye")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// Failure is the one state that earns a colour. `.red` is the system red,
    /// which is already the pair the platform picked for light and dark; the
    /// neutral states stay on the label colour so nothing competes with the
    /// data in the panels around them.
    private var symbolTint: Color {
        if case .failed = state { return .red }
        return Color.primary.opacity(0.55)
    }
}
