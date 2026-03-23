import Foundation
import UserNotifications

/// Adaptive polling monitor for Claude usage/rate-limit data.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?

    let oauthManager: ClaudeOAuthManager
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
        if oauthManager.authState == .loggedIn {
            beginPollingLoop()
        } else {
            observeLogin()
        }
    }

    private func observeLogin() {
        withObservationTracking {
            _ = oauthManager.authState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.oauthManager.authState == .loggedIn {
                    self.beginPollingLoop()
                } else {
                    self.observeLogin()
                }
            }
        }
    }

    private func beginPollingLoop() {
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
                    lastError = L.tr("사용량 조회 제한 — 잠시 후 재시도", "Rate limited — retrying shortly")
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
        // No data yet (first fetch failed or pending) — retry quickly
        if currentUsage == nil {
            return 15
        }
        // Near limit (>75%) → 120s (minimum safe interval)
        if let usage = currentUsage, usage.maxUtilization > 75 {
            return 120
        }
        // Active → 180s
        if aggregator.tokensPerMinute > 0 {
            return 180
        }
        // Default → 300s
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
