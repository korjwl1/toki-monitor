import Foundation
import UserNotifications

/// Sync connection state.
enum SyncState: Equatable {
    case notConfigured
    case configured(serverAddr: String, httpURL: String)
    case tokenExpired
}

/// Observable sync state manager.
/// Reads credentials from Keychain and exposes sync status to the UI.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    private(set) var state: SyncState = .notConfigured
    private let client: SyncClient

    var isConfigured: Bool {
        if case .notConfigured = state { return false }
        return true
    }

    var isTokenExpired: Bool {
        if case .tokenExpired = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .notConfigured:
            return L.sync.notConfigured
        case .configured(let addr, _):
            return L.tr("연결됨: \(addr)", "Connected: \(addr)")
        case .tokenExpired:
            return L.sync.tokenExpired
        }
    }

    init(client: SyncClient = .shared) {
        self.client = client
        reload()
    }

    /// Re-read credentials from Keychain and update state.
    func reload() {
        if let creds = client.load() {
            state = .configured(serverAddr: creds.serverAddr, httpURL: creds.httpURL)
        } else {
            state = .notConfigured
        }
    }

    /// Disable sync: delete Keychain credentials.
    func disable() {
        client.delete()
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
