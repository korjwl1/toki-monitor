import Foundation
import UserNotifications

/// Adaptive polling monitor for Claude usage/rate-limit data.
/// Reads authentication from Claude Code's Keychain entry.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false

    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var pollingTask: Task<Void, Never>?
    private var hasNotified75 = false
    private var hasNotified90 = false
    private var lastResetId: String?
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
            if isAvailable {
                lastError = nil
            }
            return
        }

        do {
            let usage = try await ClaudeUsageClient.fetchUsage(accessToken: token)
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            checkThresholds(usage)
        } catch let error as OAuthError {
            if case .usageFetchFailed(401) = error {
                // Token invalid/expired — Claude Code will refresh it
                lastError = nil
            } else if case .usageFetchFailed(429) = error {
                lastError = nil // Rate limited — retry on next poll
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    lastError = error.localizedDescription
                }
            }
        } catch is DecodingError {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                lastError = L.tr("응답 형식 오류", "Response format error")
            }
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        if !isAvailable { return 60 }
        if currentUsage == nil { return 15 }
        if let usage = currentUsage, usage.maxUtilization > 75 { return 120 }
        if aggregator.tokensPerMinute > 0 { return 180 }
        return 300
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: ClaudeUsageResponse) {
        let max = usage.maxUtilization

        let resetId = usage.fiveHour?.resetsAt ?? ""
        if resetId != lastResetId {
            hasNotified75 = false
            hasNotified90 = false
            lastResetId = resetId
        }

        if max >= 90 && !hasNotified90 && settings.claudeAlert90 {
            hasNotified90 = true
            sendNotification(
                title: L.tr("Claude 사용량 90% 도달", "Claude usage reached 90%"),
                body: L.tr("5시간 세션 사용량이 90%를 넘었습니다. 속도가 제한될 수 있습니다.", "5-hour session usage exceeded 90%. Rate limiting may apply.")
            )
        } else if max >= 75 && !hasNotified75 && settings.claudeAlert75 {
            hasNotified75 = true
            sendNotification(
                title: L.tr("Claude 사용량 75% 도달", "Claude usage reached 75%"),
                body: L.tr("5시간 세션 사용량이 75%를 넘었습니다.", "5-hour session usage exceeded 75%.")
            )
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
