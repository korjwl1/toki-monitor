import SwiftUI

/// Shared header component for all dashboard detail views.
/// Ensures consistent styling: icon + title on left, trailing actions on right,
/// uniform padding, background, and divider.
struct DetailHeaderView<Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let trailing: Trailing

    init(title: String, icon: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    /// Fixed header height for consistent divider position across all pages
    static var headerHeight: CGFloat { 36 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            .padding(.horizontal, 16)
            .frame(height: Self.headerHeight)
            .background(.ultraThinMaterial)

            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)
        }
    }
}
