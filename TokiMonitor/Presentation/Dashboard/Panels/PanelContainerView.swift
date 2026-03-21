import SwiftUI

/// Wrapper for any dashboard panel. Shows a GroupBox with title,
/// and in edit mode displays a drag handle and delete button.
struct PanelContainerView<Content: View>: View {
    let title: String
    let isEditing: Bool
    let onDelete: () -> Void
    @ViewBuilder let content: Content

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

                if isEditing {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
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
