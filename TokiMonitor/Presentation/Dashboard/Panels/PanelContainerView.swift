import SwiftUI

// Dashboard design system — mirrors MenuContentView DS
private enum DashDS {
    // Spacing (8pt grid)
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16

    // Typography
    static let fontTitle: CGFloat = 13
    static let fontBody: CGFloat = 12
    static let fontCaption: CGFloat = 10

    // Border radius
    static let panelRadius: CGFloat = 14
    static let innerRadius: CGFloat = 10
}

/// Wrapper for any dashboard panel. Clean card style with glass/material effect,
/// matching the menu bar widget design language.
struct PanelContainerView<Content: View>: View {
    let title: String
    let isEditing: Bool
    var alertState: AlertState?
    let onDelete: () -> Void
    let onEdit: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    init(
        title: String,
        isEditing: Bool,
        alertState: AlertState? = nil,
        onDelete: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isEditing = isEditing
        self.alertState = alertState
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DashDS.sm) {
            // Title bar
            HStack(spacing: DashDS.sm) {
                if isEditing {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: DashDS.fontBody))
                }

                Text(title)
                    .font(.system(size: DashDS.fontTitle, weight: .semibold))

                // Alert state indicator
                if let alertState {
                    Image(systemName: alertState.iconName)
                        .font(.system(size: DashDS.fontCaption))
                        .foregroundStyle(alertStateColor(alertState))
                }

                Spacer()

                // Show edit button on hover (not in edit mode)
                if isHovered && !isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: DashDS.fontBody))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                if isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: DashDS.fontBody))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: DashDS.fontBody))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)

            // Content
            content
        }
        .padding(DashDS.md)
        .modifier(PanelCardModifier(isHovered: isHovered))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: DashDS.panelRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
            // Alert border
            if let alertState, alertState == .alerting {
                RoundedRectangle(cornerRadius: DashDS.panelRadius, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.6), lineWidth: 2)
            }
        }
    }

    private func alertStateColor(_ state: AlertState) -> Color {
        switch state {
        case .ok: .green
        case .alerting: .red
        case .noData: .secondary
        }
    }
}

// MARK: - Panel Card Modifier (glass on macOS 26+, material fallback)

private struct PanelCardModifier: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: DashDS.panelRadius))
                .opacity(isHovered ? 1.0 : 0.95)
        } else {
            content
                .background(
                    isHovered ? .thinMaterial : .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: DashDS.panelRadius, style: .continuous)
                )
        }
    }
}
