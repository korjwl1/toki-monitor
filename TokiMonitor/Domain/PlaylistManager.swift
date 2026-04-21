import Foundation

/// Manages dashboard playlists and auto-cycling.
@MainActor
@Observable
final class PlaylistManager {
    private static let storeKey = "dashboardPlaylists"

    var playlists: [DashboardPlaylist] = []
    var isPlaying: Bool = false
    var currentPlaylistID: UUID?
    var currentIndex: Int = 0

    private var cycleTimer: Timer?

    init() {
        playlists = Self.loadPlaylists()
    }

    // MARK: - CRUD

    func addPlaylist(_ playlist: DashboardPlaylist) {
        playlists.append(playlist)
        savePlaylists()
    }

    func updatePlaylist(_ playlist: DashboardPlaylist) {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
            savePlaylists()
        }
    }

    func removePlaylist(id: UUID) {
        if currentPlaylistID == id { stop() }
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    // MARK: - Playback

    func play(playlistID: UUID, onSwitch: @escaping @MainActor (String) -> Void) {
        guard let playlist = playlists.first(where: { $0.id == playlistID }),
              !playlist.dashboardUIDs.isEmpty else { return }

        stop()
        currentPlaylistID = playlistID
        currentIndex = 0
        isPlaying = true

        // Switch to first dashboard
        onSwitch(playlist.dashboardUIDs[0])

        // Start cycling
        cycleTimer = Timer.scheduledTimer(withTimeInterval: playlist.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying,
                      let playlist = self.playlists.first(where: { $0.id == playlistID })
                else { return }
                self.currentIndex = (self.currentIndex + 1) % playlist.dashboardUIDs.count
                onSwitch(playlist.dashboardUIDs[self.currentIndex])
            }
        }
    }

    func pause() {
        isPlaying = false
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    func stop() {
        pause()
        currentPlaylistID = nil
        currentIndex = 0
    }

    func next(onSwitch: @escaping @MainActor (String) -> Void) {
        guard let playlistID = currentPlaylistID,
              let playlist = playlists.first(where: { $0.id == playlistID })
        else { return }
        currentIndex = (currentIndex + 1) % playlist.dashboardUIDs.count
        onSwitch(playlist.dashboardUIDs[currentIndex])
    }

    func previous(onSwitch: @escaping @MainActor (String) -> Void) {
        guard let playlistID = currentPlaylistID,
              let playlist = playlists.first(where: { $0.id == playlistID })
        else { return }
        currentIndex = (currentIndex - 1 + playlist.dashboardUIDs.count) % playlist.dashboardUIDs.count
        onSwitch(playlist.dashboardUIDs[currentIndex])
    }

    // MARK: - Persistence

    private func savePlaylists() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private static func loadPlaylists() -> [DashboardPlaylist] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let items = try? JSONDecoder().decode([DashboardPlaylist].self, from: data)
        else { return [] }
        return items
    }
}
