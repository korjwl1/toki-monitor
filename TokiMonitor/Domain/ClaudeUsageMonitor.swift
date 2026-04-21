import Foundation

// MARK: - Claude Usage Domain Models

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

    var maxUtilization: Double {
        [fiveHour?.utilization, sevenDay?.utilization, sevenDaySonnet?.utilization]
            .compactMap { $0 }.max() ?? 0
    }
}

struct UsageBucket: Codable {
    let utilization: Double   // 0-100
    let resetsAt: String?     // ISO 8601, null when unused

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    var timeUntilReset: TimeInterval? {
        guard let reset = resetDate else { return nil }
        return reset.timeIntervalSinceNow
    }

    @MainActor var resetCountdown: String {
        guard let remaining = timeUntilReset, remaining > 0 else { return L.usage.resetSoon }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return L.usage.countdown(days: days, hours: hours % 24)
        } else if hours > 0 {
            return L.usage.countdownHours(hours: hours, minutes: minutes)
        } else {
            return L.usage.countdownMinutes(minutes)
        }
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    enum CodingKeys: String, CodingKey { case isEnabled = "is_enabled" }
}

// MARK: - Claude Usage Monitor

/// Adaptive polling monitor for Claude usage/rate-limit data.
/// Reads authentication from Claude Code's Keychain entry.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false
    var isPolling: Bool { pollingTask != nil }
    var isInBackoff: Bool { consecutiveFailures > 0 }

    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var pollingTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    init(aggregator: TokenAggregator, settings: AppSettings) {
        self.aggregator = aggregator
        self.settings = settings
        self.isAvailable = ClaudeAuthReader.isAvailable
    }

    // MARK: - Start/Stop

    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let interval = self.computeInterval()
                self.sleepTask = Task {
                    try? await Task.sleep(for: .seconds(interval))
                }
                await self.sleepTask?.value
                self.sleepTask = nil
            }
        }
    }

    func stopPolling() {
        sleepTask?.cancel()
        sleepTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 현재 sleep 중이면 즉시 중단하고 다음 poll을 앞당깁니다.
    func wakeForImmediatePoll() {
        guard pollingTask != nil else { return }
        sleepTask?.cancel()
    }

    // MARK: - Polling

    private func pollOnce() async {
        // Re-check availability each poll (user may install/login to Claude Code later)
        isAvailable = ClaudeAuthReader.isAvailable

        guard let token = ClaudeAuthReader.readAccessToken() else {
            if isAvailable { lastError = nil }
            return
        }

        do {
            let usage = try await ClaudeUsageClient.fetchUsage(accessToken: token)
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            settings.claudeHasSevenDaySonnet = (usage.sevenDaySonnet != nil)
            checkThresholds(usage)
        } catch let error as OAuthError {
            if case .usageFetchFailed(401) = error {
                lastError = nil // Token invalid/expired — Claude Code will refresh it
            } else if case .usageFetchFailed(429) = error {
                lastError = nil // Rate limited — retry on next poll
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 { lastError = error.localizedDescription }
            }
        } catch is DecodingError {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { lastError = L.tr("응답 형식 오류", "Response format error") }
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { lastError = error.localizedDescription }
        }
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        if !isAvailable { return 60 }
        // Backoff capped at 60s: recovers within 1 minute after transient server errors
        if consecutiveFailures > 0 {
            return min(15 * pow(2, Double(consecutiveFailures - 1)), 60)
        }
        if currentUsage == nil { return 15 }
        // High utilization or heavy token flow → poll aggressively
        if let usage = currentUsage, usage.maxUtilization > 75 { return 60 }
        if aggregator.tokensPerMinute > 5000 { return 60 }
        if aggregator.tokensPerMinute > 0 { return 120 }
        return 300
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: ClaudeUsageResponse) {
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .claudeFiveHour,       utilization: usage.fiveHour?.utilization,       resetId: usage.fiveHour?.resetsAt),
            .init(bucket: .claudeSevenDay,       utilization: usage.sevenDay?.utilization,       resetId: usage.sevenDay?.resetsAt),
            .init(bucket: .claudeSevenDaySonnet, utilization: usage.sevenDaySonnet?.utilization, resetId: usage.sevenDaySonnet?.resetsAt),
        ], providerTitle: L.panel.claudeUsage, settings: settings)
    }
}
