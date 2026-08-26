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
    /// What kind of panel this is, for the reader who cannot see it. Without
    /// it "1.2M" could be a lone number or the end of a line (FR-063).
    var panelType: PanelType?
    /// What the panel currently says, already formatted by whichever render
    /// owns the number. Nil in every state that has no value to speak.
    var valueSummary: String?
    let onDelete: () -> Void
    let onEdit: () -> Void
    /// Re-runs this panel's query. Only `.failed` offers it.
    var onRetry: (() -> Void)?
    /// Un-hides every series. Only `.empty(.allSeriesHidden)` offers it — and
    /// it must, because that state draws instead of the chart and takes the
    /// legend off screen with it.
    var onShowAllSeries: (() -> Void)?
    /// Queries of THIS panel that did not answer, keyed by refId, while at
    /// least one other did (contract Q5). The panel keeps drawing what it has —
    /// blanking it would throw away good data because of one bad query — so the
    /// only way a reader learns that a series is missing is this marker.
    var failedTargets: [String: String] = [:]
    /// Ad hoc filters the reader set that this panel's query could not be
    /// given (contract Q4). The panel is drawing real data — it is just not
    /// the narrowed data the toolbar says it is, and only this says so.
    var filterNotices: [String] = []
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
    /// Keyboard focus on the card itself. It does two jobs: it is what makes
    /// the edit and inspect controls appear without a mouse (FR-061), and it
    /// is what draws the focus ring that says where the keyboard is (FR-062).
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        isEditing: Bool,
        state: PanelState? = nil,
        panelType: PanelType? = nil,
        valueSummary: String? = nil,
        onDelete: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onRetry: (() -> Void)? = nil,
        onShowAllSeries: (() -> Void)? = nil,
        failedTargets: [String: String] = [:],
        filterNotices: [String] = [],
        onInspect: (() -> Void)? = nil,
        isRepeatInstance: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEditing = isEditing
        self.state = state
        self.panelType = panelType
        self.valueSummary = valueSummary
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onShowAllSeries = onShowAllSeries
        self.failedTargets = failedTargets
        self.filterNotices = filterNotices
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
                    .foregroundStyle(DS.bodySecondary)
            }
            .font(.system(size: DS.fontTiny))
            .help(detail)
            .accessibilityLabel(
                L.tr("일부 쿼리가 실패했습니다. \(detail)",
                     "Some queries failed. \(detail)")
            )
        }
    }

    /// The filter the toolbar shows and this panel does not have.
    ///
    /// Beside the title for the same reason the partial-failure badge is: what
    /// is drawn is real data, so replacing it with a message would be a lie in
    /// the other direction. The full reason — which filter, and why it could
    /// not be placed — is in the tooltip and read out by VoiceOver.
    @ViewBuilder
    private var unappliedFilterBadge: some View {
        if !filterNotices.isEmpty {
            let detail = filterNotices.joined(separator: "\n")
            HStack(spacing: DS.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.orange)
                Text(L.tr("필터 미적용", "Filter not applied"))
                    .foregroundStyle(DS.bodySecondary)
            }
            .font(.system(size: DS.fontTiny))
            .help(detail)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                L.tr("이 패널에는 필터가 적용되지 않았습니다. \(detail)",
                     "A filter set on this dashboard was not applied to this panel. \(detail)")
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Title bar
            HStack(spacing: DS.sm) {
                if isEditing && !isRepeatInstance {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(DS.iconSecondary)
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
                unappliedFilterBadge

                Spacer()

                // Edit + inspect appear on hover OR on keyboard focus. Hover
                // alone made them unreachable without a mouse (FR-061): there
                // was no state a keyboard could put the panel into that
                // brought them on screen at all.
                if (isHovered || isFocused) && !isEditing {
                    if let onInspect {
                        Button(action: onInspect) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: DS.fontBody))
                                .foregroundStyle(DS.iconSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .transition(.opacity)
                        .help(L.tr("데이터·쿼리 검사", "Inspect data and query"))
                        .accessibilityLabel(L.tr("\(title) 검사", "Inspect \(title)"))
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: DS.fontBody))
                            .foregroundStyle(DS.iconSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .transition(.opacity)
                    .help(L.tr("패널 편집", "Edit panel"))
                    .accessibilityLabel(L.tr("\(title) 편집", "Edit \(title)"))
                }

                if isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: DS.fontBody))
                            .foregroundStyle(DS.iconSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .help(L.tr("패널 편집", "Edit panel"))
                    .accessibilityLabel(L.tr("\(title) 편집", "Edit \(title)"))

                    if !isRepeatInstance {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: DS.fontBody))
                                .foregroundStyle(DS.iconSecondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .help(L.tr("패널 삭제", "Delete panel"))
                        .accessibilityLabel(L.tr("\(title) 삭제", "Delete \(title)"))
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
                    PanelStatusView(state: state, onRetry: onRetry,
                                    onShowAllSeries: onShowAllSeries)
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
            withAnimation(Motion.reveal(reduceMotion)) {
                isHovered = hovering
            }
        }
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(DS.borderStrong)
            }
        }
        // The focus ring. Drawn by the panel rather than left to the system
        // because the card is a custom shape: the default ring is a rectangle
        // and lands outside the rounded corners.
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focused($isFocused)
        // Keyboard, on the focused panel. The buttons in the title bar are the
        // tabbable path; these are the direct one, so reaching inspect does not
        // cost a tab through every panel control before it.
        .onKeyPress(.return) { activatePrimary() }
        .onKeyPress(KeyEquivalent("i")) { activatePrimary() }
        .onKeyPress(KeyEquivalent("e")) {
            onEdit()
            return .handled
        }
        .onKeyPress(.delete) {
            guard isEditing, !isRepeatInstance else { return .ignored }
            onDelete()
            return .handled
        }
        // What the whole card announces: what it is, what state it is in, and
        // what it says (FR-063). `.contain` rather than `.combine` — the retry
        // button, the legend and the badges inside must stay reachable as
        // elements of their own.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            PanelAccessibility.announcement(
                title: title,
                typeName: (panelType ?? .unknown).displayName,
                state: state,
                value: state?.showsContent == false ? nil : valueSummary
            )
        )
        .accessibilityHint(
            PanelAccessibility.hint(canInspect: onInspect != nil,
                                    canEdit: true,
                                    canDelete: isEditing && !isRepeatInstance) ?? ""
        )
        .accessibilityAction(named: L.tr("검사", "Inspect")) { onInspect?() }
        .accessibilityAction(named: L.tr("편집", "Edit")) { onEdit() }
        .accessibilityActions {
            if isEditing && !isRepeatInstance {
                Button(L.tr("삭제", "Delete"), action: onDelete)
            }
            if let onRetry, state?.offersRetry == true {
                Button(L.tr("다시 시도", "Retry"), action: onRetry)
            }
        }
    }

    /// Return and `i` both open the inspector — "where did this number come
    /// from" is the question a reader asks of a panel they have just landed on.
    /// A panel with no inspector leaves the key to whatever is behind it.
    private func activatePrimary() -> KeyPress.Result {
        guard let onInspect else { return .ignored }
        onInspect()
        return .handled
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
