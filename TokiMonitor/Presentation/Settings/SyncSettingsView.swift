import SwiftUI

struct SyncSettingsView: View {
    @State private var syncManager = SyncManager.shared
    @State private var showLoginSheet = false
    @State private var showDeviceList = false
    @State private var errorMessage: String?
    /// Cached toki settings JSON, loaded once on appear to avoid repeated disk reads.
    @State private var cachedSettings: [String: Any]?
    /// Cached sync state JSON (runtime status, separate from settings).
    @State private var cachedSyncState: [String: Any]?
    /// Editable device name (populated from Keychain on appear).
    @State private var editingDeviceName: String = ""
    @State private var isEditingName = false
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        Form {
            if syncManager.isConfigured {
                connectedSection
            } else {
                Section {
                    stateRow
                        .background(scrollTopTracker)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L.sync.title)
        .sheet(isPresented: $showLoginSheet) {
            SyncLoginSheet {
                showLoginSheet = false
                syncManager.reload()
                errorMessage = nil
                loadSettings()
                if let creds = SyncClient.shared.load() {
                    editingDeviceName = creds.deviceName
                }
            }
        }
        .sheet(isPresented: $showDeviceList) {
            DeviceListSheet()
        }
        .onAppear {
            loadSettings()
            if let creds = SyncClient.shared.load() {
                editingDeviceName = creds.deviceName
            }
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
            if case .configured(let addr, let url, _) = syncManager.state {
                LabeledContent(L.sync.serverAddress, value: addr)
                    .background(scrollTopTracker)
                LabeledContent("HTTP URL", value: url)
            }

            // Connection status indicator
            HStack {
                Text(L.tr("연결 상태", "Connection Status"))
                Spacer()
                liveStatusLabel
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
                deviceNameRow
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

    // MARK: - Live status label

    @ViewBuilder
    private var liveStatusLabel: some View {
        switch syncManager.liveStatus {
        case .connected:
            Label(L.tr("연결됨", "Connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .disconnected:
            Label(L.tr("연결 끊김", "Disconnected"), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .authFailed:
            Label(L.tr("인증 실패", "Auth Failed"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .tokenExpired:
            Label(L.tr("토큰 만료", "Token Expired"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .unknown:
            Label(L.tr("확인 중…", "Checking…"), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - Editable device name

    @ViewBuilder
    private var deviceNameRow: some View {
        LabeledContent(L.tr("기기 이름", "Device Name")) {
            if isEditingName {
                HStack(spacing: 4) {
                    TextField("", text: $editingDeviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .focused($isNameFieldFocused)
                        .onSubmit { saveDeviceName() }
                    Button {
                        saveDeviceName()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    Button {
                        isEditingName = false
                        // Reset to current value
                        if let creds = SyncClient.shared.load() {
                            editingDeviceName = creds.deviceName
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 4) {
                    Text(editingDeviceName.isEmpty ? "-" : editingDeviceName)
                        .foregroundStyle(.secondary)
                    Button {
                        isEditingName = true
                        isNameFieldFocused = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func saveDeviceName() {
        let trimmed = editingDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SyncClient.shared.renameDevice(trimmed)
            editingDeviceName = trimmed
            SyncClient.shared.invalidateCache()
        } catch {
            errorMessage = error.localizedDescription
        }
        isEditingName = false
    }

    /// Load toki settings and sync state from disk (called on `.onAppear`).
    private func loadSettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // User settings
        if let data = try? Data(contentsOf: home.appendingPathComponent(".config/toki/settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cachedSettings = json
        } else {
            cachedSettings = nil
        }
        // Sync runtime state
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/toki/sync_state.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cachedSyncState = json
        } else {
            cachedSyncState = nil
        }
    }

    /// Read last sync time. `sync_last_success` lives in sync_state.json,
    /// `sync_last_ts_*` cursors live in settings.json.
    private func lastSyncTimeText() -> String {
        // Primary: sync_last_success from sync_state.json (epoch seconds)
        if let state = cachedSyncState,
           let raw = state["sync_last_success"] as? String,
           let ts = Int64(raw), ts > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            return Self.syncDateFormatter.string(from: date)
        }

        // Fallback: latest sync_last_ts_* from settings.json (epoch millis)
        guard let json = cachedSettings else { return "N/A" }
        var latestTs: Int64 = 0
        for (key, value) in json {
            if key.hasPrefix("sync_last_ts_") {
                let ts: Int64
                if let s = value as? String, let parsed = Int64(s) {
                    ts = parsed
                } else if let n = value as? NSNumber {
                    ts = n.int64Value
                } else {
                    continue
                }
                if ts > latestTs { latestTs = ts }
            }
        }

        guard latestTs > 0 else { return "N/A" }
        let date = Date(timeIntervalSince1970: TimeInterval(latestTs) / 1000.0)
        return Self.syncDateFormatter.string(from: date)
    }

    private static let syncDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

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
        case .configured(let addr, _, _):
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
    @State private var deviceToRemove: DeviceInfo?
    @Environment(\.dismiss) private var dismiss

    private var currentDeviceKey: String {
        SyncClient.shared.load()?.deviceKey ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.tr("기기 목록", "Device List"))
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            } else if let err = errorMessage {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(err)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if devices.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L.tr("등록된 기기 없음", "No devices registered"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
            } else {
                List {
                    ForEach(sortedDevices) { device in
                        let isCurrent = device.deviceKey == currentDeviceKey
                        HStack(spacing: 12) {
                            Image(systemName: isCurrent ? "laptopcomputer" : "desktopcomputer")
                                .font(.title3)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.name)
                                        .font(.body)
                                        .fontWeight(isCurrent ? .medium : .regular)
                                    if isCurrent {
                                        Circle()
                                            .fill(.green)
                                            .frame(width: 8, height: 8)
                                        Text(L.tr("이 기기", "This Device"))
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor, in: Capsule())
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(device.lastSeenText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(device.id)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            Spacer()

                            if !isCurrent {
                                Button {
                                    deviceToRemove = device
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 340)
        .alert(
            L.tr("기기 삭제", "Remove Device"),
            isPresented: Binding(
                get: { deviceToRemove != nil },
                set: { if !$0 { deviceToRemove = nil } }
            )
        ) {
            Button(L.tr("삭제", "Remove"), role: .destructive) {
                if let device = deviceToRemove {
                    Task { await removeDevice(device) }
                }
            }
            Button(L.tr("취소", "Cancel"), role: .cancel) {}
        } message: {
            if let device = deviceToRemove {
                Text(L.tr("'\(device.name)' 기기를 서버에서 삭제하시겠습니까?",
                           "Remove '\(device.name)' from the server?"))
            }
        }
        .task { await fetchDevices() }
    }

    private func removeDevice(_ device: DeviceInfo) async {
        do {
            let data = try await CLIProcessRunner.run(
                executable: TokiPath.resolved,
                arguments: ["settings", "sync", "remove", device.id]
            )
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains("error") || output.contains("failed") {
                errorMessage = output
            } else {
                devices.removeAll { $0.id == device.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sorted so the current device appears first.
    private var sortedDevices: [DeviceInfo] {
        devices.sorted { a, _ in a.deviceKey == currentDeviceKey }
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
            let deviceKey = d["device_key"] as? String ?? ""

            // last_seen_at may be Int, Int64, Double, or String
            let lastSeenTs: TimeInterval?
            if let n = d["last_seen_at"] as? NSNumber {
                lastSeenTs = n.doubleValue
            } else if let s = d["last_seen_at"] as? String, let v = Double(s) {
                lastSeenTs = v
            } else {
                lastSeenTs = nil
            }

            let lastSeenText: String
            if let ts = lastSeenTs, ts > 0 {
                let date = Date(timeIntervalSince1970: ts)
                let rel = RelativeDateTimeFormatter()
                rel.unitsStyle = .abbreviated
                lastSeenText = rel.localizedString(for: date, relativeTo: Date())
            } else {
                lastSeenText = "-"
            }

            return DeviceInfo(id: id, deviceKey: deviceKey, name: name, lastSeenText: lastSeenText)
        }
    }
}

private struct DeviceInfo: Identifiable {
    let id: String
    let deviceKey: String
    let name: String
    let lastSeenText: String
}

// MARK: - Login Sheet

private struct SyncLoginSheet: View {
    var onComplete: () -> Void

    @State private var server = ""
    @State private var syncPort = "9090"
    @State private var httpPort = "9091"
    @State private var noTLS = false
    @State private var insecure = false
    @State private var isRunning = false
    @State private var statusText = ""
    @State private var userCode: String?
    @State private var errorMessage: String?
    @State private var cliProcess: Process?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.sync.enableSync)
                    .font(.headline)
                Spacer()
                Button(L.tr("취소", "Cancel")) {
                    cliProcess?.terminate()
                    dismiss()
                }
            }
            .padding()

            Divider()

            if isRunning {
                // Waiting for CLI to complete (browser auth in progress)
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(L.tr("브라우저에서 인증을 완료하세요", "Complete authentication in your browser"))
                        .font(.headline)
                    if let userCode {
                        Text(userCode)
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundStyle(Color.accentColor)
                    }
                    ProgressView()
                        .controlSize(.small)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                Form {
                    Section {
                        TextField(
                            L.tr("서버 주소", "Server Address"),
                            text: $server,
                            prompt: Text("example.com / 127.0.0.1")
                        )
                    }
                    Section {
                        TextField(
                            L.tr("Sync 포트", "Sync Port"),
                            text: $syncPort,
                            prompt: Text("9090")
                        )
                        .help(L.tr("TCP 동기화 포트 (기본값: 9090)", "TCP sync port (default: 9090)"))
                        TextField(
                            L.tr("HTTP 포트", "HTTP Port"),
                            text: $httpPort,
                            prompt: Text("9091")
                        )
                        .help(L.tr("HTTP API 포트 (기본값: 9091)", "HTTP API port (default: 9091)"))
                    }
                    Section {
                        Toggle(L.tr("TLS 비활성화 (로컬 전용)", "Disable TLS (local only)"), isOn: $noTLS)
                        Toggle(L.tr("자체 서명 인증서 허용", "Allow self-signed certificates"), isOn: $insecure)
                            .disabled(noTLS)
                    }
                }
                .formStyle(.grouped)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if !isRunning {
                Divider()
                HStack {
                    Spacer()
                    Button(L.tr("연결", "Connect")) { runSyncEnable() }
                        .buttonStyle(.borderedProminent)
                        .disabled(server.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
        }
        .frame(width: 420, height: isRunning ? 280 : nil)
        .onDisappear { cliProcess?.terminate() }
    }

    private func runSyncEnable() {
        isRunning = true
        errorMessage = nil
        statusText = L.tr("서버에 연결 중…", "Connecting to server…")

        let host = server.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["settings", "sync", "enable",
                    "--server", host,
                    "--sync-port", syncPort.isEmpty ? "9090" : syncPort,
                    "--http-port", httpPort.isEmpty ? "9091" : httpPort]
        if noTLS { args.append("--no-tls") }
        if insecure { args.append("--insecure") }

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice

            // Capture stderr for status messages
            let errPipe = Pipe()
            process.standardError = errPipe

            await MainActor.run { cliProcess = process }

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
                return
            }

            // Read stderr in background to show progress and parse user code
            let errHandle = errPipe.fileHandleForReading
            Task.detached {
                while true {
                    let data = errHandle.availableData
                    if data.isEmpty { break }
                    if let text = String(data: data, encoding: .utf8) {
                        await MainActor.run {
                            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                                // Parse user code: "[toki] Then enter code: XXXX-XXXX"
                                if line.contains("enter code:") {
                                    let parts = line.components(separatedBy: "enter code:")
                                    if let code = parts.last?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
                                        userCode = code
                                    }
                                }
                                // Update status text
                                let clean = line
                                    .replacingOccurrences(of: "[toki] ", with: "")
                                    .replacingOccurrences(of: "[toki:sync] ", with: "")
                                    .trimmingCharacters(in: .whitespaces)
                                if !clean.isEmpty {
                                    statusText = clean
                                }
                            }
                        }
                    }
                }
            }

            process.waitUntilExit()

            await MainActor.run {
                if process.terminationStatus == 0 {
                    // Success — CLI handled everything (credentials, settings, browser auth)
                    SyncClient.shared.invalidateCache()
                    SyncManager.shared.reload()
                    onComplete()
                } else {
                    errorMessage = L.tr("연결 실패 (코드: \(process.terminationStatus))", "Connection failed (code: \(process.terminationStatus))")
                    isRunning = false
                }
            }
        }
    }
}

// MARK: - View helper

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
