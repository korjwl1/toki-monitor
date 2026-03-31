import Foundation
import UserNotifications

/// Sync connection state.
enum SyncState: Equatable {
    case notConfigured
    case configured(serverAddr: String, httpURL: String, liveStatus: SyncLiveStatus)
    case tokenExpired
}

/// Live connection status read from `sync_status` in toki settings.
enum SyncLiveStatus: String, Equatable {
    case connected
    case disconnected
    case authFailed = "auth_failed"
    case tokenExpired = "token_expired"
    case unknown
}

/// Observable sync state manager.
/// Reads credentials from Keychain and exposes sync status to the UI.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    private(set) var state: SyncState = .notConfigured
    private let client: SyncClient

    private var pollTimer: Timer?

    var isConfigured: Bool {
        if case .notConfigured = state { return false }
        return true
    }

    var isTokenExpired: Bool {
        if case .tokenExpired = state { return true }
        return false
    }

    var liveStatus: SyncLiveStatus {
        if case .configured(_, _, let status) = state { return status }
        return .unknown
    }

    var statusText: String {
        switch state {
        case .notConfigured:
            return L.sync.notConfigured
        case .configured(let addr, _, _):
            return L.tr("연결됨: \(addr)", "Connected: \(addr)")
        case .tokenExpired:
            return L.sync.tokenExpired
        }
    }

    init(client: SyncClient = .shared) {
        self.client = client
        reload()
        startPolling()
    }

    /// Re-read credentials from Keychain and update state.
    func reload() {
        if let creds = client.load() {
            let live = Self.readLiveStatus()
            state = .configured(serverAddr: creds.serverAddr, httpURL: creds.httpURL, liveStatus: live)
        } else {
            state = .notConfigured
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveStatus()
            }
        }
    }

    private func refreshLiveStatus() {
        switch state {
        case .configured(let addr, let url, _):
            let live = Self.readLiveStatus()
            state = .configured(serverAddr: addr, httpURL: url, liveStatus: live)
        case .notConfigured:
            // Check if sync was re-enabled since last check
            reload()
        }
    }

    private static func readLiveStatus() -> SyncLiveStatus {
        let stateURL = URL(fileURLWithPath: "/tmp/toki/sync_state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["sync_status"] as? String, !raw.isEmpty else {
            return .unknown
        }
        return SyncLiveStatus(rawValue: raw) ?? .unknown
    }

    /// Disable sync via toki CLI (handles Keychain cleanup, settings, etc.)
    func disable() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
        process.arguments = ["settings", "sync", "disable", "--keep"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        client.invalidateCache()
        state = .notConfigured
    }

    /// Mark token as expired (e.g. after a 401 that couldn't be refreshed).
    func markTokenExpired() {
        state = .tokenExpired
        sendReloginNotification()
    }

    // MARK: - Notification

    private func sendReloginNotification() {
        let content = UNMutableNotificationContent()
        content.title = L.sync.reloginTitle
        content.body  = L.sync.reloginBody
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "toki-sync-relogin", content: content, trigger: nil)
        )
    }
}
