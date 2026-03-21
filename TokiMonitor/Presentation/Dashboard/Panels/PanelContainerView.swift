import SwiftUI

/// Wrapper for any dashboard panel. Shows a GroupBox with title,
/// and in edit mode displays a drag handle and delete button.
/// Double-click opens the panel editor.
struct PanelContainerView<Content: View>: View {
    let title: String
    let isEditing: Bool
    let onDelete: () -> Void
    let onEdit: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        GroupBox {
            content
        } label: {
            HStack {
                if isEditing {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                }

                Text(title)
                    .font(.headline)

                Spacer()

                // Show edit button on hover (not in edit mode)
                if isHovered && !isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                if isEditing {
                    Button(action: onEdit) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture(count: 2) {
            onEdit()
        }
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
    }
}
