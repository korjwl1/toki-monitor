import Foundation
import UserNotifications

/// Adaptive polling monitor for Claude usage/rate-limit data.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?

    private let oauthManager: ClaudeOAuthManager
    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var pollingTask: Task<Void, Never>?
    private var hasNotified75 = false
    private var hasNotified90 = false
    private var lastResetId: String?  // track reset period changes

    init(oauthManager: ClaudeOAuthManager, aggregator: TokenAggregator, settings: AppSettings) {
        self.oauthManager = oauthManager
        self.aggregator = aggregator
        self.settings = settings
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
        guard oauthManager.authState == .loggedIn else {
            currentUsage = nil
            return
        }

        do {
            let token = try await oauthManager.getValidAccessToken()
            let usage = try await ClaudeUsageClient.fetchUsage(accessToken: token)
            currentUsage = usage
            checkThresholds(usage)
        } catch {
            // On permanent auth failure, usage becomes nil
            if case .permanentAuthFailure = error as? OAuthError {
                currentUsage = nil
            }
            // Transient errors: keep old data, retry on next tick
        }
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        // Near limit → 15s
        if let usage = currentUsage, usage.maxUtilization > 75 {
            return 15
        }

        // Active (tokens flowing) → 30s
        if aggregator.tokensPerMinute > 0 {
            return 30
        }

        // Idle (no events for 5min) → 5min
        // Check via tokensPerMinute being 0 for a while
        // Since we don't track "time since last event", use rate as proxy
        return 60  // default
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: ClaudeUsageResponse) {
        let max = usage.maxUtilization

        // Track reset period to clear notification flags
        let resetId = usage.fiveHour?.resetsAt ?? ""
        if resetId != lastResetId {
            hasNotified75 = false
            hasNotified90 = false
            lastResetId = resetId
        }

        if max >= 90 && !hasNotified90 && settings.claudeAlert90 {
            hasNotified90 = true
            sendNotification(
                title: "Claude 사용량 90% 도달",
                body: "5시간 세션 사용량이 90%를 넘었습니다. 속도가 제한될 수 있습니다."
            )
        } else if max >= 75 && !hasNotified75 && settings.claudeAlert75 {
            hasNotified75 = true
            sendNotification(
                title: "Claude 사용량 75% 도달",
                body: "5시간 세션 사용량이 75%를 넘었습니다."
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
