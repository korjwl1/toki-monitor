import Foundation
import Security

/// Sync credentials stored in macOS Keychain.
/// Keys match `toki sync enable` CLI (toki/src/sync/credentials.rs).
struct SyncCredentials: Codable {
    var serverAddr: String   // host:port for TCP sync
    var httpURL: String      // HTTPS base URL for HTTP API
    var accessToken: String
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case serverAddr   = "server_addr"
        case httpURL      = "http_url"
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
    }
}

/// Manages toki sync credentials in the macOS Keychain.
/// Service "toki-sync" / Account "credentials" — matches the toki CLI.
@MainActor
final class SyncClient {
    static let shared = SyncClient()

    private let service = "toki-sync"
    private let account = "credentials"

    // MARK: - Keychain

    func load() -> SyncCredentials? {
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
        return try? JSONDecoder().decode(SyncCredentials.self, from: data)
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
    }

    func delete() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - HTTP Login

    /// POST /login with username/password. Saves credentials to Keychain on success.
    func login(httpURL: String, serverAddr: String, username: String, password: String) async throws -> SyncCredentials {
        guard let url = URL(string: "\(httpURL)/login") else { throw SyncClientError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])

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
            refreshToken: refresh
        )
        try save(creds)
        return creds
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
        return updated
    }
}

enum SyncClientError: LocalizedError {
    case keychainError(OSStatus)
    case invalidURL
    case invalidResponse
    case invalidCredentials
    case serverError(String)
    case missingToken
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .keychainError(let s):  return "Keychain error (\(s))"
        case .invalidURL:            return L.tr("잘못된 서버 URL", "Invalid server URL")
        case .invalidResponse:       return L.tr("잘못된 응답", "Invalid response")
        case .invalidCredentials:    return L.tr("잘못된 사용자명 또는 비밀번호", "Invalid username or password")
        case .serverError(let m):    return m
        case .missingToken:          return L.tr("서버에서 토큰을 받지 못했습니다", "Server did not return a token")
        case .refreshFailed:         return L.tr("토큰 갱신 실패", "Token refresh failed")
        }
    }
}
