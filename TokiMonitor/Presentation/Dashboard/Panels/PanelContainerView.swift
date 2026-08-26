import SwiftUI


/// Wrapper for any dashboard panel. Clean card style with glass/material effect,
/// matching the menu bar widget design language.
struct PanelContainerView<Content: View>: View {
    let title: String
    let isEditing: Bool
    /// What the panel is showing. `nil` for a panel that manages its own
    /// content entirely (a row header), which is why this is optional rather
    /// than defaulting to `.idle`.
    var state: PanelState?
    let onDelete: () -> Void
    let onEdit: () -> Void
    /// Re-runs this panel's query. Only `.failed` offers it.
    var onRetry: (() -> Void)?
    /// Queries of THIS panel that did not answer, keyed by refId, while at
    /// least one other did (contract Q5). The panel keeps drawing what it has —
    /// blanking it would throw away good data because of one bad query — so the
    /// only way a reader learns that a series is missing is this marker.
    var failedTargets: [String: String] = [:]
    /// Inspect is available whether or not the dashboard is in edit mode: the
    /// question it answers ("where did this number come from?") is asked while
    /// READING a dashboard, not while building one.
    var onInspect: (() -> Void)?
    /// A copy a `repeat` produced, rather than a panel of its own. It has no
    /// separate definition to delete or to drag, so it offers neither — and
    /// its edit button opens the panel it is a copy OF.
    var isRepeatInstance: Bool = false
    @ViewBuilder let content: Content

    @State private var isHovered = false

    init(
        title: String,
        isEditing: Bool,
        state: PanelState? = nil,
        onDelete: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onRetry: (() -> Void)? = nil,
        failedTargets: [String: String] = [:],
        onInspect: (() -> Void)? = nil,
        isRepeatInstance: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEditing = isEditing
        self.state = state
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.failedTargets = failedTargets
        self.onInspect = onInspect
        self.isRepeatInstance = isRepeatInstance
        self.content = content()
    }

    /// Which queries failed, in refId order, with their reasons in the tooltip.
    /// Shown beside the title rather than in place of the content: the content
    /// is still true, it is just incomplete.
    @ViewBuilder
    private var partialFailureBadge: some View {
        if !failedTargets.isEmpty {
            let refIds = failedTargets.keys.sorted()
            let detail = refIds.map { "\($0): \(failedTargets[$0] ?? "")" }
                .joined(separator: "\n")
            HStack(spacing: DS.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L.tr("쿼리 \(refIds.joined(separator: ", ")) 실패",
                          "Query \(refIds.joined(separator: ", ")) failed"))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: DS.fontTiny))
            .help(detail)
            .accessibilityLabel(
                L.tr("일부 쿼리가 실패했습니다. \(detail)",
                     "Some queries failed. \(detail)")
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Title bar
            HStack(spacing: DS.sm) {
                if isEditing && !isRepeatInstance {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: DS.fontBody))
                }

                Text(title)
                    .font(.system(size: DS.Dashboard.panelTitleFont, weight: .semibold))
                    // Named, not inherited. A `Text` that states no colour
                    // takes it from the AppKit drawing appearance rather than
                    // from the SwiftUI colour scheme, so under a forced scheme
                    // — a snapshot, a preview, a window mid-appearance-change —
                    // the title drew black on a dark card.
                    .foregroundStyle(Color.primary)

                partialFailureBadge

                Spacer()

                // Show edit + inspect on hover (not in edit mode)
                if isHovered && !isEditing {
                    if let onInspect {
                        Button(action: onInspect) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: DS.fontBody))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                        .help(L.tr("데이터·쿼리 검사", "Inspect data and query"))
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: DS.fontBody))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                if isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: DS.fontBody))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isRepeatInstance {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: DS.fontBody))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)

            // Content — one branch per state (contract R3). These used to be
            // three: idle, loading and loaded shared a branch and drew the
            // content regardless, so "nothing yet", "nothing here" and
            // "on its way" were the same empty rectangle.
            if let state {
                switch state {
                case .loaded:
                    content
                case .loading(hasPrevious: true):
                    // The previous result stays on screen, dimmed, with the
                    // progress marker in the corner. Clearing it made every
                    // time-range change flash the whole dashboard blank, which
                    // reads as a fault rather than as a refresh.
                    content
                        .opacity(0.45)
                        .allowsHitTesting(false)
                        .overlay(alignment: .topTrailing) {
                            ProgressView()
                                .controlSize(.small)
                                .padding(DS.xs)
                        }
                        .accessibilityLabel(
                            L.tr("이전 결과 — 새로 불러오는 중",
                                 "Previous result — refreshing")
                        )
                case .idle, .loading(hasPrevious: false), .empty, .failed:
                    PanelStatusView(state: state, onRetry: onRetry)
                }
            } else {
                content
            }
        }
        .padding(DS.md)
        // Force the full padded rectangle to be hit-testable so .onHover fires
        // anywhere inside the card — not just where chart pixels are drawn.
        // Without this, the title bar / edit button area sits outside the
        // hit region and the button disappears the moment the cursor leaves
        // the drawn data, making it unreachable.
        .contentShape(Rectangle())
        .modifier(PanelCardModifier(isHovered: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
    }
}

// MARK: - Panel Card Modifier (glass on macOS 26+, material fallback)

private struct PanelCardModifier: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: DS.panelRadius))
                .opacity(isHovered ? 1.0 : 0.95)
        } else {
            content
                .background(
                    isHovered ? .thinMaterial : .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous)
                )
        }
    }
}
