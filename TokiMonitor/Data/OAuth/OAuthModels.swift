import Foundation

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
    let resetsAt: String?     // ISO 8601, null when unused

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    /// Parse reset time to Date.
    var resetDate: Date? {
        guard let resetsAt else { return nil }
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
    case usageFetchFailed(Int)

    var errorDescription: String? {
        switch self {
        case .usageFetchFailed(let code): "Usage fetch failed (\(code))"
        }
    }
}
