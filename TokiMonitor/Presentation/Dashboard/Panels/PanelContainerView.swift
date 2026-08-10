import SwiftUI


/// Wrapper for any dashboard panel. Clean card style with glass/material effect,
/// matching the menu bar widget design language.
struct PanelContainerView<Content: View>: View {
    let title: String
    let isEditing: Bool
    var dataState: PanelDataState?
    let onDelete: () -> Void
    let onEdit: () -> Void
    /// Inspect is available whether or not the dashboard is in edit mode: the
    /// question it answers ("where did this number come from?") is asked while
    /// READING a dashboard, not while building one.
    var onInspect: (() -> Void)?
    @ViewBuilder let content: Content

    @State private var isHovered = false

    init(
        title: String,
        isEditing: Bool,
        dataState: PanelDataState? = nil,
        onDelete: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onInspect: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEditing = isEditing
        self.dataState = dataState
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onInspect = onInspect
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            // Title bar
            HStack(spacing: DS.sm) {
                if isEditing {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: DS.fontBody))
                }

                Text(title)
                    .font(.system(size: DS.Dashboard.panelTitleFont, weight: .semibold))

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

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DS.fontBody))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)

            // Content — with centralized data state handling
            if let state = dataState {
                switch state {
                case .idle, .loading, .loaded:
                    // Always show panel frame; content renders empty chart if no data yet
                    content
                case .error(let message):
                    ContentUnavailableView(
                        L.tr("오류", "Error"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
