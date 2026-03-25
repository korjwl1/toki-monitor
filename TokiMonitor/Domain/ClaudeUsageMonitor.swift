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
    /// Per-window alert state keyed by resetsAt timestamp.
    /// Once a threshold fires for a given resetId, it won't fire again until the window resets.
    private var notifiedWindows: [String: Set<Int>] = [:]  // resetId → {75, 90}
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
        // Exponential backoff on consecutive failures: 15s, 30s, 60s, 120s, max 300s
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
        let windows: [(bucket: UsageBucket?, label: String)] = [
            (usage.fiveHour, L.tr("5시간 세션", "5-hour session")),
            (usage.sevenDay, L.tr("7일", "7-day")),
            (usage.sevenDaySonnet, L.tr("7일 Sonnet", "7-day Sonnet")),
        ]

        // Prune stale entries — only keep resetIds that are still active
        let activeResetIds = Set(windows.compactMap { $0.bucket?.resetsAt })
        notifiedWindows = notifiedWindows.filter { activeResetIds.contains($0.key) }

        for (bucket, label) in windows {
            guard let bucket, let resetId = bucket.resetsAt else { continue }
            let util = bucket.utilization
            var notified = notifiedWindows[resetId] ?? []

            if util >= 90 && !notified.contains(90) && settings.claudeAlert90 {
                notified.insert(90)
                sendNotification(
                    title: L.tr("Claude 사용량 90% 도달", "Claude usage reached 90%"),
                    body: L.tr("\(label) 사용량이 90%를 넘었습니다. 속도가 제한될 수 있습니다.",
                               "\(label) usage exceeded 90%. Rate limiting may apply.")
                )
            } else if util >= 75 && !notified.contains(75) && settings.claudeAlert75 {
                notified.insert(75)
                sendNotification(
                    title: L.tr("Claude 사용량 75% 도달", "Claude usage reached 75%"),
                    body: L.tr("\(label) 사용량이 75%를 넘었습니다.",
                               "\(label) usage exceeded 75%.")
                )
            }

            notifiedWindows[resetId] = notified
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
