import Foundation

/// Adaptive polling monitor for Claude usage/rate-limit data.
/// Reads authentication from Claude Code's Keychain entry.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false
    var isPolling: Bool { pollingTask != nil }

    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var pollingTask: Task<Void, Never>?
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
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
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
        if consecutiveFailures > 0 {
            return min(15 * pow(2, Double(consecutiveFailures - 1)), 300)
        }
        if currentUsage == nil { return 15 }
        if let usage = currentUsage, usage.maxUtilization > 75 { return 120 }
        if aggregator.tokensPerMinute > 0 { return 180 }
        return 300
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: ClaudeUsageResponse) {
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .claudeFiveHour,      utilization: usage.fiveHour?.utilization,      resetId: usage.fiveHour?.resetsAt      ?? "unknown"),
            .init(bucket: .claudeSevenDay,      utilization: usage.sevenDay?.utilization,      resetId: usage.sevenDay?.resetsAt      ?? "unknown"),
            .init(bucket: .claudeSevenDaySonnet, utilization: usage.sevenDaySonnet?.utilization, resetId: usage.sevenDaySonnet?.resetsAt ?? "unknown"),
        ], providerTitle: L.panel.claudeUsage, settings: settings)
    }
}
