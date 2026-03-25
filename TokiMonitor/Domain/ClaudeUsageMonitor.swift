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
            settings.claudeHasSevenDaySonnet = (usage.sevenDaySonnet != nil)
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
        let buckets: [(UsageAlertBucket, UsageBucket?)] = [
            (.claudeFiveHour, usage.fiveHour),
            (.claudeSevenDay, usage.sevenDay),
            (.claudeSevenDaySonnet, usage.sevenDaySonnet)
        ]

        for (bucketType, bucket) in buckets {
            guard let bucket else { continue }
            let utilization = bucket.utilization
            let resetId = bucket.resetsAt ?? "unknown"

            if utilization >= 90,
               settings.usageAlert90Enabled,
               settings.isUsageAlertBucketEnabled(.percent90, bucket: bucketType) {
                if !UsageAlertStateStore.shared.hasNotified(
                    threshold: .percent90,
                    bucket: bucketType,
                    resetId: resetId
                ) {
                    UsageAlertStateStore.shared.markNotified(
                        threshold: .percent90,
                        bucket: bucketType,
                        resetId: resetId
                    )
                    sendUsageNotification(
                        providerTitle: L.panel.claudeUsage,
                        bucketLabel: bucketType.displayName,
                        threshold: 90
                    )
                }
                continue
            }

            if utilization >= 75,
               settings.usageAlert75Enabled,
               settings.isUsageAlertBucketEnabled(.percent75, bucket: bucketType) {
                if !UsageAlertStateStore.shared.hasNotified(
                    threshold: .percent75,
                    bucket: bucketType,
                    resetId: resetId
                ) {
                    UsageAlertStateStore.shared.markNotified(
                        threshold: .percent75,
                        bucket: bucketType,
                        resetId: resetId
                    )
                    sendUsageNotification(
                        providerTitle: L.panel.claudeUsage,
                        bucketLabel: bucketType.displayName,
                        threshold: 75
                    )
                }
            }
        }
    }

    private func sendUsageNotification(providerTitle: String, bucketLabel: String, threshold: Int) {
        sendNotification(
            title: L.tr("\(providerTitle) \(threshold)% 도달", "\(providerTitle) reached \(threshold)%"),
            body: L.tr("\(bucketLabel) 사용량이 \(threshold)%를 넘었습니다.", "\(bucketLabel) usage exceeded \(threshold)%.")
        )
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
