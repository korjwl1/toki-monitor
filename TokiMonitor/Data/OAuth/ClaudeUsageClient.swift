import Foundation

/// Fetches Claude usage/rate-limit data from Anthropic's OAuth API.
struct ClaudeUsageClient: Sendable {
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// Fetch current usage data.
    static func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
        guard let url = URL(string: usageURL) else { throw OAuthError.usageFetchFailed(0) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("toki-monitor/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.usageFetchFailed(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw OAuthError.usageFetchFailed(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    }
}
