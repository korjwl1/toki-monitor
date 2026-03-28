import SwiftUI

struct SyncSettingsView: View {
    @State private var syncManager = SyncManager.shared
    @State private var showLoginSheet = false
    @State private var showDeviceList = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                stateRow
                    .background(Color.clear.preference(key: ScrollTopYKey.self, value: 0))
                    .scrollTopTracker
            }

            if syncManager.isConfigured {
                connectedSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L.sync.title)
        .sheet(isPresented: $showLoginSheet) {
            SyncLoginSheet { result in
                showLoginSheet = false
                switch result {
                case .success:
                    syncManager.reload()
                    errorMessage = nil
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
        .sheet(isPresented: $showDeviceList) {
            DeviceListSheet()
        }
        .if(errorMessage != nil) { view in
            view.overlay(alignment: .bottom) {
                Text(errorMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Connected state section

    @ViewBuilder
    private var connectedSection: some View {
        Section(L.sync.status) {
            if case .configured(let addr, let url) = syncManager.state {
                LabeledContent(L.sync.serverAddress, value: addr)
                LabeledContent("HTTP URL", value: url)
            }

            // Connection status indicator
            HStack {
                Text(L.tr("연결 상태", "Connection Status"))
                Spacer()
                if case .tokenExpired = syncManager.state {
                    Label(L.tr("토큰 만료", "Token Expired"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Label(L.tr("연결됨", "Connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            // Device ID & Name from Keychain credentials
            if let creds = SyncClient.shared.load() {
                if !creds.deviceKey.isEmpty {
                    LabeledContent(L.tr("기기 ID", "Device ID")) {
                        Text(creds.deviceKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !creds.deviceName.isEmpty {
                    LabeledContent(L.tr("기기 이름", "Device Name"), value: creds.deviceName)
                }
            }

            // Last sync time
            LabeledContent(L.tr("마지막 동기화", "Last Sync")) {
                Text(lastSyncTimeText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Device list button
            Button {
                showDeviceList = true
            } label: {
                Label(L.tr("기기 목록", "Device List"), systemImage: "desktopcomputer")
            }

            Button(role: .destructive) {
                syncManager.disable()
            } label: {
                Label(L.sync.disableSync, systemImage: "xmark.circle")
            }
        }
    }

    /// Read last sync time from toki settings if available.
    private func lastSyncTimeText() -> String {
        // Try reading from toki settings file (~/.config/toki/settings.json)
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/toki/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "N/A"
        }

        // Check sync_last_ts_claude_code (or any sync_last_ts_* key)
        var latestTs: Int64 = 0
        for (key, value) in json {
            if key.hasPrefix("sync_last_ts_"), let ts = value as? Int64, ts > latestTs {
                latestTs = ts
            }
        }

        guard latestTs > 0 else { return "N/A" }
        let date = Date(timeIntervalSince1970: TimeInterval(latestTs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var stateRow: some View {
        switch syncManager.state {
        case .notConfigured:
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text(L.sync.notConfigured)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.sync.enableSync) { showLoginSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .configured(let addr, _):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L.tr("연결됨", "Connected"))
                Spacer()
                Text(addr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tokenExpired:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L.sync.tokenExpired)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.sync.login) { showLoginSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Device List Sheet

private struct DeviceListSheet: View {
    @State private var devices: [DeviceInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var currentDeviceKey: String {
        SyncClient.shared.load()?.deviceKey ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.tr("기기 목록", "Device List"))
                    .font(.headline)
                Spacer()
                Button(L.tr("닫기", "Close")) { dismiss() }
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let err = errorMessage {
                Spacer()
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding()
                Spacer()
            } else if devices.isEmpty {
                Spacer()
                Text(L.tr("등록된 기기 없음", "No devices registered"))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(device.name)
                                    .font(.body)
                                if device.id == currentDeviceKey {
                                    Text(L.tr("(현재)", "(current)"))
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                            }
                            Text(device.lastSeenText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 400, height: 320)
        .task { await fetchDevices() }
    }

    private func fetchDevices() async {
        guard let creds = SyncClient.shared.load() else {
            errorMessage = L.tr("동기화가 설정되지 않았습니다", "Sync is not configured")
            isLoading = false
            return
        }

        let urlString = "\(creds.httpURL)/me/devices"
        guard let url = URL(string: urlString) else {
            errorMessage = L.tr("잘못된 URL", "Invalid URL")
            isLoading = false
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                errorMessage = L.tr("잘못된 응답", "Invalid response")
                isLoading = false
                return
            }

            if http.statusCode == 401 {
                // Try refresh
                do {
                    let updated = try await SyncClient.shared.refreshAccessToken(creds)
                    var retryReq = URLRequest(url: url, timeoutInterval: 15)
                    retryReq.setValue("Bearer \(updated.accessToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResp) = try await URLSession.shared.data(for: retryReq)
                    guard let retryHttp = retryResp as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        errorMessage = L.tr("기기 목록을 불러올 수 없습니다", "Failed to load device list")
                        isLoading = false
                        return
                    }
                    parseDevices(from: retryData)
                } catch {
                    errorMessage = L.tr("토큰 만료. 다시 로그인하세요.", "Token expired. Please re-login.")
                }
                isLoading = false
                return
            }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                errorMessage = body
                isLoading = false
                return
            }

            parseDevices(from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func parseDevices(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceArray = json["devices"] as? [[String: Any]] else {
            errorMessage = L.tr("응답 파싱 실패", "Failed to parse response")
            return
        }

        devices = deviceArray.map { d in
            let id = d["id"] as? String ?? "-"
            let name = d["name"] as? String ?? "-"
            let lastSeen = d["last_seen_at"] as? Int64

            let lastSeenText: String
            if let ts = lastSeen, ts > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                lastSeenText = formatter.string(from: date)
            } else {
                lastSeenText = "-"
            }

            return DeviceInfo(id: id, name: name, lastSeenText: lastSeenText)
        }
    }
}

private struct DeviceInfo: Identifiable {
    let id: String
    let name: String
    let lastSeenText: String
}

// MARK: - Login Sheet

private struct SyncLoginSheet: View {
    var onComplete: (Result<SyncCredentials, Error>) -> Void

    @State private var httpURL = "https://"
    @State private var serverAddr = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.sync.enableSync)
                    .font(.headline)
                Spacer()
                Button(L.tr("취소", "Cancel")) { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField(L.sync.serverURL, text: $httpURL)
                        .textContentType(.URL)
                    TextField(L.sync.syncAddr, text: $serverAddr)
                        .textContentType(.URL)
                        .help(L.tr("TCP 동기화 주소 (예: sync.example.com:9090)", "TCP sync address (e.g. sync.example.com:9090)"))
                }
                Section {
                    TextField(L.sync.username, text: $username)
                        .textContentType(.username)
                    SecureField(L.sync.password, text: $password)
                        .textContentType(.password)
                }
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            HStack {
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L.sync.login) { performLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(httpURL.isEmpty || username.isEmpty || password.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 420)
    }

    private func performLogin() {
        isLoading = true
        errorMessage = nil
        let httpBase = httpURL.hasSuffix("/") ? String(httpURL.dropLast()) : httpURL
        let addr = serverAddr.isEmpty ? deriveAddr(from: httpBase) : serverAddr

        Task { @MainActor in
            do {
                let creds = try await SyncClient.shared.login(
                    httpURL: httpBase, serverAddr: addr,
                    username: username, password: password
                )
                isLoading = false
                onComplete(.success(creds))
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deriveAddr(from httpURL: String) -> String {
        guard let host = URLComponents(string: httpURL)?.host else { return httpURL }
        return "\(host):9090"
    }
}

// MARK: - View helper

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
