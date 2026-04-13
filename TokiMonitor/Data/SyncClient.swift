import Foundation
import Security

/// Sync credentials stored in macOS Keychain.
/// Keys match `toki sync enable` CLI (toki/src/sync/credentials.rs).
struct SyncCredentials: Codable {
    var serverAddr: String   // host:port for TCP sync
    var httpURL: String      // HTTPS base URL for HTTP API
    var accessToken: String
    var refreshToken: String
    var deviceKey: String
    var deviceName: String

    enum CodingKeys: String, CodingKey {
        case serverAddr   = "server_addr"
        case httpURL      = "http_url"
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case deviceKey    = "device_key"
        case deviceName   = "device_name"
    }

    init(serverAddr: String, httpURL: String, accessToken: String, refreshToken: String,
         deviceKey: String = "", deviceName: String = "") {
        self.serverAddr = serverAddr
        self.httpURL = httpURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceKey = deviceKey
        self.deviceName = deviceName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverAddr   = try container.decode(String.self, forKey: .serverAddr)
        httpURL      = try container.decode(String.self, forKey: .httpURL)
        accessToken  = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        deviceKey    = try container.decodeIfPresent(String.self, forKey: .deviceKey) ?? ""
        deviceName   = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
    }
}

/// Manages toki sync credentials in the macOS Keychain.
/// Service "toki-sync" / Account "credentials" — matches the toki CLI.
@MainActor
final class SyncClient {
    static let shared = SyncClient()

    private let service = "toki-sync"
    private let account = "credentials"

    /// In-memory credential cache to avoid repeated Keychain reads.
    private var cachedCredentials: SyncCredentials?

    // MARK: - Keychain

    func load() -> SyncCredentials? {
        // Always read from Keychain — cost is ~ms, and credentials may be
        // updated externally by `toki settings sync enable/disable`.
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let creds = try? JSONDecoder().decode(SyncCredentials.self, from: data)
        return creds
    }

    /// Invalidate the in-memory credential cache, forcing the next `load()` to read from Keychain.
    func invalidateCache() {
        cachedCredentials = nil
    }

    func save(_ creds: SyncCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let baseQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SyncClientError.keychainError(status)
        }
        invalidateCache()
    }

    func delete() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        invalidateCache()
    }

    // MARK: - HTTP Login

    /// POST /login with username/password. Saves credentials to Keychain on success.
    func login(httpURL: String, serverAddr: String, username: String, password: String,
                deviceKey: String = "", deviceName: String = "") async throws -> SyncCredentials {
        guard httpURL.lowercased().hasPrefix("https://")
                || httpURL.hasPrefix("http://localhost")
                || httpURL.hasPrefix("http://127.0.0.1") else {
            throw SyncClientError.insecureURL
        }
        guard let url = URL(string: "\(httpURL)/login") else { throw SyncClientError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["username": username, "password": password]
        if !deviceKey.isEmpty {
            body["device_id"] = deviceKey
        }
        if !deviceName.isEmpty {
            body["device_name"] = deviceName
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncClientError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw SyncClientError.invalidCredentials
        default:
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SyncClientError.serverError(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access  = json["access_token"]  as? String,
              let refresh = json["refresh_token"] as? String else {
            throw SyncClientError.missingToken
        }

        let creds = SyncCredentials(
            serverAddr:   serverAddr,
            httpURL:      httpURL,
            accessToken:  access,
            refreshToken: refresh,
            deviceKey:    deviceKey,
            deviceName:   deviceName
        )
        try save(creds)
        invalidateCache()
        return creds
    }

    /// Rename device via toki CLI. toki handles both Keychain and settings update.
    func renameDevice(_ newName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TokiPath.resolved)
        process.arguments = ["settings", "sync", "rename", newName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SyncClientError.invalidResponse
        }
    }

    /// POST /token/refresh. Saves updated credentials to Keychain on success.
    func refreshAccessToken(_ creds: SyncCredentials) async throws -> SyncCredentials {
        guard let url = URL(string: "\(creds.httpURL)/token/refresh") else { throw SyncClientError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": creds.refreshToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncClientError.refreshFailed
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access  = json["access_token"]  as? String,
              let refresh = json["refresh_token"] as? String else {
            throw SyncClientError.missingToken
        }
        var updated = creds
        updated.accessToken  = access
        updated.refreshToken = refresh
        try save(updated)
        invalidateCache()
        return updated
    }
}

enum SyncClientError: LocalizedError {
    case keychainError(OSStatus)
    case invalidURL
    case insecureURL
    case invalidResponse
    case invalidCredentials
    case serverError(String)
    case missingToken
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .keychainError(let s):  return "Keychain error (\(s))"
        case .invalidURL:            return L.tr("잘못된 서버 URL", "Invalid server URL")
        case .insecureURL:           return L.tr("HTTPS가 필요합니다 (localhost 제외)", "HTTPS is required (except localhost)")
        case .invalidResponse:       return L.tr("잘못된 응답", "Invalid response")
        case .invalidCredentials:    return L.tr("잘못된 사용자명 또는 비밀번호", "Invalid username or password")
        case .serverError(let m):    return m
        case .missingToken:          return L.tr("서버에서 토큰을 받지 못했습니다", "Server did not return a token")
        case .refreshFailed:         return L.tr("토큰 갱신 실패", "Token refresh failed")
        }
    }
}
