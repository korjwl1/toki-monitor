import Foundation

// MARK: - Codex Auth Error (Data layer — thrown by CodexAuthReader/CodexUsageClient)

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

// MARK: - Codex Auth Token Reader

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
                // 해당 경로에 auth.json이 실제로 있을 때만 적용 (잘못된 경로로 덮어쓰기 방지)
                let candidateAuthPath = path + "/auth.json"
                if FileManager.default.fileExists(atPath: candidateAuthPath) {
                    codexRoot = path
                }
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
