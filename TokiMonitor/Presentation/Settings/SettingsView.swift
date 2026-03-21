import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case providers
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "일반"
        case .menuBar: "메뉴바"
        case .providers: "프로바이더"
        case .notifications: "알림"
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

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            detailView
        }
        .navigationSplitViewColumnWidth(min: 440, ideal: 480)
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
