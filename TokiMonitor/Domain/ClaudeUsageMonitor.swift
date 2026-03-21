import Foundation
import UserNotifications

/// Adaptive polling monitor for Claude usage/rate-limit data.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?

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
            lastError = nil
            checkThresholds(usage)
        } catch let error as OAuthError {
            if case .usageFetchFailed(429) = error {
                // Rate limited — refresh token to get a new ~5-request window
                lastError = nil // Don't show 429 to user, handle silently
                do {
                    let newToken = try await oauthManager.forceRefreshToken()
                    let usage = try await ClaudeUsageClient.fetchUsage(accessToken: newToken)
                    currentUsage = usage
                    checkThresholds(usage)
                } catch {
                    // Refresh retry also failed — wait for next poll
                    lastError = "사용량 조회 제한 — 잠시 후 재시도"
                }
            } else if case .permanentAuthFailure = error {
                currentUsage = nil
                lastError = error.localizedDescription
            } else {
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        // Usage API is severely rate-limited (~5 requests per access token).
        // Minimum 120s between polls to stay under limit.
        // Near limit (>75%) → 120s (minimum safe interval)
        // Active → 180s
        // Default → 300s
        if let usage = currentUsage, usage.maxUtilization > 75 {
            return 120
        }
        if aggregator.tokensPerMinute > 0 {
            return 180
        }
        return 300
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
