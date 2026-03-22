import SwiftUI

/// Playlist management view with create/edit/play controls.
struct PlaylistView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var showCreatePlaylist = false
    @State private var editingPlaylist: DashboardPlaylist?
    @State private var newPlaylistName = ""
    @State private var newPlaylistInterval: Double = 30

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderView(title: L.dash.playlists, icon: "play.rectangle") {
                Button {
                    showCreatePlaylist = true
                } label: {
                    Label(L.dash.newPlaylist, systemImage: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }

            if viewModel.playlistManager.playlists.isEmpty {
                ContentUnavailableView(
                    L.tr("재생목록이 없습니다", "No playlists"),
                    systemImage: "play.rectangle",
                    description: Text(L.tr("대시보드를 자동으로 순환하는 재생목록을 만들어보세요", "Create a playlist to auto-cycle through dashboards"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.playlistManager.playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            createPlaylistSheet
        }
        .sheet(item: $editingPlaylist) { playlist in
            editPlaylistSheet(playlist)
        }
    }

    private func playlistRow(_ playlist: DashboardPlaylist) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.subheadline.bold())
                Text("\(playlist.dashboardUIDs.count) \(L.dash.dashboards) - \(Int(playlist.interval))s \(L.dash.interval)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Play
            Button {
                viewModel.playlistManager.play(playlistID: playlist.id) { uid in
                    viewModel.switchDashboard(uid: uid)
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            // Edit
            Button {
                editingPlaylist = playlist
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            // Delete
            Button(role: .destructive) {
                viewModel.playlistManager.removePlaylist(id: playlist.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Create Playlist Sheet

    private var createPlaylistSheet: some View {
        VStack(spacing: 16) {
            Text(L.dash.newPlaylist)
                .font(.headline)

            TextField(L.tr("이름", "Name"), text: $newPlaylistName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(L.dash.interval)
                Slider(value: $newPlaylistInterval, in: 5...300, step: 5)
                Text("\(Int(newPlaylistInterval))s")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }

            // Dashboard selector
            Text(L.tr("대시보드 선택", "Select dashboards"))
                .font(.subheadline.bold())

            ScrollView {
                let list = viewModel.dashboardList
                VStack(spacing: 4) {
                    ForEach(list, id: \.uid) { dashboard in
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .font(.caption)
                            Text(dashboard.title)
                                .font(.caption)
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button(L.dash.cancel) {
                    showCreatePlaylist = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L.dash.add) {
                    let playlist = DashboardPlaylist(
                        name: newPlaylistName,
                        dashboardUIDs: viewModel.dashboardList.map(\.uid),
                        interval: newPlaylistInterval
                    )
                    viewModel.playlistManager.addPlaylist(playlist)
                    newPlaylistName = ""
                    showCreatePlaylist = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPlaylistName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Edit Playlist Sheet

    private func editPlaylistSheet(_ playlist: DashboardPlaylist) -> some View {
        EditPlaylistView(
            playlist: playlist,
            dashboardList: viewModel.dashboardList
        ) { updated in
            viewModel.playlistManager.updatePlaylist(updated)
            editingPlaylist = nil
        }
    }
}

/// Sub-view for editing a playlist.
struct EditPlaylistView: View {
    @State private var playlist: DashboardPlaylist
    let dashboardList: [DashboardConfig]
    let onSave: (DashboardPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss

    init(playlist: DashboardPlaylist, dashboardList: [DashboardConfig], onSave: @escaping (DashboardPlaylist) -> Void) {
        _playlist = State(initialValue: playlist)
        self.dashboardList = dashboardList
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(L.tr("재생목록 편집", "Edit Playlist"))
                .font(.headline)

            TextField(L.tr("이름", "Name"), text: $playlist.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(L.dash.interval)
                Slider(value: $playlist.interval, in: 5...300, step: 5)
                Text("\(Int(playlist.interval))s")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }

            Text(L.tr("대시보드 선택", "Select dashboards"))
                .font(.subheadline.bold())

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(dashboardList, id: \.uid) { dashboard in
                        let included = playlist.dashboardUIDs.contains(dashboard.uid)
                        Button {
                            if included {
                                playlist.dashboardUIDs.removeAll { $0 == dashboard.uid }
                            } else {
                                playlist.dashboardUIDs.append(dashboard.uid)
                            }
                        } label: {
                            HStack {
                                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
                                Text(dashboard.title)
                                    .font(.caption)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button(L.dash.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.tr("저장", "Save")) {
                    onSave(playlist)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
