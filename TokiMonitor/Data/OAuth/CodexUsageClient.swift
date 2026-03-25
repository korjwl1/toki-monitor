import Foundation

// MARK: - Codex Usage Response

struct CodexUsageResponse: Codable {
    let planType: String
    let rateLimit: CodexRateLimit
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

struct CodexRateLimit: Codable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexUsageWindow: Codable {
    let usedPercent: Int
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    /// Human-readable reset countdown.
    var resetCountdown: String {
        let totalHours = resetAfterSeconds / 3600
        let m = (resetAfterSeconds % 3600) / 60
        if totalHours >= 24 {
            let d = totalHours / 24
            let h = totalHours % 24
            return L.tr("\(d)일 \(h)시간", "\(d)d \(h)h")
        }
        if totalHours > 0 {
            return L.tr("\(totalHours)시간 \(m)분", "\(totalHours)h \(m)m")
        }
        return L.tr("\(m)분", "\(m)m")
    }

    /// Window label localized (e.g. "5시간", "7일").
    var windowLabel: String {
        let hours = limitWindowSeconds / 3600
        if hours >= 24 {
            let days = hours / 24
            return L.tr("\(days)일", "\(days)d")
        }
        return L.tr("\(hours)시간", "\(hours)h")
    }
}

struct CodexCredits: Codable {
    let hasCredits: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try container.decode(Bool.self, forKey: .hasCredits)
        // API returns balance as either Double or String — handle both
        if let d = try? container.decode(Double.self, forKey: .balance) {
            balance = d
        } else if let s = try? container.decode(String.self, forKey: .balance) {
            balance = Double(s)
        } else {
            balance = nil
        }
    }
}

// MARK: - Codex Auth Token Reader

enum CodexAuthError: Error, LocalizedError {
    case authFileNotFound
    case tokenMissing
    case tokenExpired
    case fetchFailed(Int)
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .authFileNotFound: "~/.codex/auth.json not found"
        case .tokenMissing: "Access token missing in auth.json"
        case .tokenExpired: "Access token expired"
        case .fetchFailed(let code): "Codex usage fetch failed (\(code))"
        case .refreshFailed: "Token refresh failed"
        }
    }
}

struct CodexAuthReader {
    /// Resolved codex root from toki settings. Set once at app startup.
    @MainActor static var codexRoot: String = NSHomeDirectory() + "/.codex"

    @MainActor static var authFilePath: String {
        codexRoot + "/auth.json"
    }

    /// Query toki settings for codex_root and cache it.
    @MainActor static func resolveCodexRoot() async {
        do {
            let data = try await CLIProcessRunner.run(
                executable: TokiPath.resolved,
                arguments: ["settings", "get", "codex_root"]
            )
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                codexRoot = path
            }
        } catch {
            // Fall back to default
        }
    }

    @MainActor static func readAccessToken() throws -> String {
        let url = URL(fileURLWithPath: authFilePath)
        guard FileManager.default.fileExists(atPath: authFilePath) else {
            throw CodexAuthError.authFileNotFound
        }

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tokens = json?["tokens"] as? [String: Any]

        guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty else {
            throw CodexAuthError.tokenMissing
        }

        return accessToken
    }

    @MainActor static func readRefreshToken() throws -> String {
        let url = URL(fileURLWithPath: authFilePath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tokens = json?["tokens"] as? [String: Any]

        guard let refreshToken = tokens?["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CodexAuthError.tokenMissing
        }

        return refreshToken
    }

    @MainActor static func readAccountId() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return nil }
        return tokens["account_id"] as? String
    }

    /// Check if auth.json exists (user has logged in to Codex at least once).
    @MainActor static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: authFilePath)
    }
}

// MARK: - Codex Usage Client

struct CodexUsageClient: Sendable {
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    static func fetchUsage(accessToken: String, accountId: String? = nil) async throws -> CodexUsageResponse {
        guard let url = URL(string: usageURL) else { throw CodexAuthError.fetchFailed(0) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("toki-monitor/1.0", forHTTPHeaderField: "User-Agent")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexAuthError.fetchFailed(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw CodexAuthError.fetchFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }
}
