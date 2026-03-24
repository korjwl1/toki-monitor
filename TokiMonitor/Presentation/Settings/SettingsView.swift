import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case providers
    case notifications
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L.cat.general
        case .menuBar: L.cat.menuBar
        case .providers: L.cat.providers
        case .notifications: L.cat.notifications
        case .about: L.cat.about
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .menuBar: "menubar.rectangle"
        case .providers: "building.2"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onClose: (() -> Void)?

    @State private var selectedCategory: SettingsCategory? = .menuBar

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 192)
        } detail: {
            detailView
                .navigationSplitViewColumnWidth(min: 400, ideal: 480)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsPane(settings: settings, onClose: onClose)
        case .menuBar:
            MenuBarSettingsPane(settings: settings)
        case .providers:
            ProvidersSettingsPane(settings: settings)
        case .notifications:
            NotificationsSettingsPane(settings: settings)
        case .about:
            AboutPane()
        case nil:
            Text(L.cat.menuBar)
                .foregroundStyle(.secondary)
        }
    }
}
