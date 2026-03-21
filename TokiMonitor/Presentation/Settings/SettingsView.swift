import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case providers
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L.cat.general
        case .menuBar: L.cat.menuBar
        case .providers: L.cat.providers
        case .notifications: L.cat.notifications
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .menuBar: "menubar.rectangle"
        case .providers: "building.2"
        case .notifications: "bell"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let oauthManager: ClaudeOAuthManager?
    var onClose: (() -> Void)?

    @State private var selectedCategory: SettingsCategory = .menuBar
    @State private var sidebarExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                // Collapse toggle
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sidebarExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }

                // Category list
                VStack(spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        sidebarButton(category)
                    }
                }
                .padding(.horizontal, 6)

                Spacer()
            }
            .frame(width: sidebarExpanded ? 180 : 52)
            .background(.ultraThinMaterial)

            Divider()

            // Detail
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebarButton(_ category: SettingsCategory) -> some View {
        Button(action: { selectedCategory = category }) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)

                if sidebarExpanded {
                    Text(category.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, sidebarExpanded ? 10 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectedCategory == category
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedCategory == category ? .primary : .secondary)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsPane(settings: settings, onClose: onClose)
        case .menuBar:
            MenuBarSettingsPane(settings: settings)
        case .providers:
            ProvidersSettingsPane(settings: settings, oauthManager: oauthManager)
        case .notifications:
            NotificationsSettingsPane(settings: settings)
        }
    }
}
