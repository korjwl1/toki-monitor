import Foundation

// MARK: - OAuth Tokens

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
    var needsProactiveRefresh: Bool { Date() >= expiresAt.addingTimeInterval(-300) }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

/// Raw token response from Anthropic's OAuth token endpoint.
struct OAuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }

    func toTokens() -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(Double(expiresIn))
        )
    }
}

// MARK: - Claude Usage Response

struct ClaudeUsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    /// Highest utilization across all buckets.
    var maxUtilization: Double {
        [fiveHour?.utilization, sevenDay?.utilization, sevenDaySonnet?.utilization]
            .compactMap { $0 }
            .max() ?? 0
    }
}

struct UsageBucket: Codable {
    let utilization: Double   // 0-100
    let resetsAt: String      // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Parse reset time to Date.
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
            ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    /// Time remaining until reset.
    var timeUntilReset: TimeInterval? {
        guard let reset = resetDate else { return nil }
        return reset.timeIntervalSinceNow
    }

    /// Formatted countdown string.
    @MainActor var resetCountdown: String {
        guard let remaining = timeUntilReset, remaining > 0 else { return L.usage.resetSoon }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            let remHours = hours % 24
            return L.usage.countdown(days: days, hours: remHours)
        } else if hours > 0 {
            return L.usage.countdownHours(hours: hours, minutes: minutes)
        } else {
            return L.usage.countdownMinutes(minutes)
        }
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }
}

// MARK: - OAuth Errors

enum OAuthError: Error, LocalizedError {
    case callbackFailed(String)
    case tokenExchangeFailed(Int, String)
    case tokenRefreshFailed(Int, String)
    case usageFetchFailed(Int)
    case noTokens
    case permanentAuthFailure

    var errorDescription: String? {
        switch self {
        case .callbackFailed(let msg): "OAuth callback failed: \(msg)"
        case .tokenExchangeFailed(let code, let msg): "Token exchange failed (\(code)): \(msg)"
        case .tokenRefreshFailed(let code, let msg): "Token refresh failed (\(code)): \(msg)"
        case .usageFetchFailed(let code): "Usage fetch failed (\(code))"
        case .noTokens: "No OAuth tokens available"
        case .permanentAuthFailure: "Authentication permanently failed"
        }
    }

    /// Whether this error is transient (worth retrying) vs permanent.
    var isTransient: Bool {
        switch self {
        case .tokenRefreshFailed(let code, _):
            return code == 429 || code >= 500
        case .usageFetchFailed(let code):
            return code == 429 || code >= 500
        case .callbackFailed, .tokenExchangeFailed:
            return false
        case .noTokens, .permanentAuthFailure:
            return false
        }
    }
}
