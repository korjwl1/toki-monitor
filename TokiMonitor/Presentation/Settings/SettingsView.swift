import SwiftUI

// MARK: - Scroll Top Tracking

/// Tracks the Y position of the first Form section in the "settingsDetail" coordinate space.
/// Used to detect when content has scrolled into the non-interactive toolbar dead zone.
struct ScrollTopYKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Scroll Top Tracker Helper

extension View {
    /// Attach to the first row of a Form to track scroll position in the "settingsDetail" coordinate space.
    var scrollTopTracker: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ScrollTopYKey.self, value: geo.frame(in: .named("settingsDetail")).minY)
        }
    }
}

// MARK: - Settings Category

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
    @State private var initialSectionY: CGFloat = .infinity
    @State private var currentSectionY: CGFloat = .infinity

    private var isScrolledIntoDeadZone: Bool {
        guard initialSectionY != .infinity else { return false }
        return currentSectionY < initialSectionY - 5
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 192)
        } detail: {
            ZStack(alignment: .top) {
                detailView

                // Gradient overlay: indicates content has scrolled into the non-clickable toolbar dead zone.
                // ignoresSafeArea extends it to the window top so it starts visually at the very edge.
                LinearGradient(
                    stops: [
                        .init(color: Color(.windowBackgroundColor).opacity(0.92), location: 0),
                        .init(color: Color(.windowBackgroundColor).opacity(0.85), location: 0.35),
                        .init(color: Color(.windowBackgroundColor).opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
                .ignoresSafeArea(.all, edges: .top)
                .allowsHitTesting(false)
                .opacity(isScrolledIntoDeadZone ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isScrolledIntoDeadZone)
            }
            .coordinateSpace(name: "settingsDetail")
            .onPreferenceChange(ScrollTopYKey.self) { y in
                if initialSectionY == .infinity {
                    initialSectionY = y
                }
                currentSectionY = y
            }
            .onChange(of: selectedCategory) { _, _ in
                initialSectionY = .infinity
                currentSectionY = .infinity
            }
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
