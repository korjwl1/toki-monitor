import Foundation
import UserNotifications

/// Polls Codex (OpenAI) usage/rate-limit data from ChatGPT backend API.
/// Reads OAuth token from ~/.codex/auth.json (written by Codex CLI login).
/// Watches auth.json for changes via DispatchSource to recover from token expiry.
@MainActor
@Observable
final class CodexUsageMonitor {
    private(set) var currentUsage: CodexUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false

    private var pollingTask: Task<Void, Never>?
    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var consecutiveFailures = 0
    private var fileWatcher: DispatchSourceFileSystemObject?

    init(aggregator: TokenAggregator, settings: AppSettings) {
        self.aggregator = aggregator
        self.settings = settings
        self.isAvailable = CodexAuthReader.isAvailable
    }

    // MARK: - Start/Stop

    func startPolling() {
        guard CodexAuthReader.isAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        stopPolling()
        startFileWatcher()
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
        stopFileWatcher()
    }

    // MARK: - Polling

    private func pollOnce() async {
        // Re-check availability (user might delete auth.json)
        guard CodexAuthReader.isAvailable else {
            isAvailable = false
            currentUsage = nil
            return
        }

        do {
            let token = try CodexAuthReader.readAccessToken()
            let accountId = CodexAuthReader.readAccountId()
            let usage = try await CodexUsageClient.fetchUsage(accessToken: token, accountId: accountId)
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            settings.codexHasSecondaryWindow = (usage.rateLimit.secondaryWindow != nil)
            checkThresholds(usage)
        } catch let error as CodexAuthError {
            switch error {
            case .fetchFailed(401), .fetchFailed(403):
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
                }
            case .fetchFailed(429):
                lastError = nil
                consecutiveFailures += 1
            case .authFileNotFound, .tokenMissing:
                isAvailable = false
                currentUsage = nil
                lastError = nil
            default:
                lastError = error.localizedDescription
                consecutiveFailures += 1
            }
        } catch {
            lastError = error.localizedDescription
            consecutiveFailures += 1
        }
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: CodexUsageResponse) {
        let windows: [(UsageAlertBucket, CodexUsageWindow?)] = [
            (.codexPrimary, usage.rateLimit.primaryWindow),
            (.codexSecondary, usage.rateLimit.secondaryWindow)
        ]

        for (bucketType, window) in windows {
            guard let window else { continue }
            let utilization = Double(window.usedPercent)
            let resetId = String(window.resetAt)

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
                        providerTitle: L.tr("Codex 사용량", "Codex Usage"),
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
                        providerTitle: L.tr("Codex 사용량", "Codex Usage"),
                        bucketLabel: bucketType.displayName,
                        threshold: 75
                    )
                }
            }
        }
    }

    private func sendUsageNotification(providerTitle: String, bucketLabel: String, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = L.tr("\(providerTitle) \(threshold)% 도달", "\(providerTitle) reached \(threshold)%")
        content.body = L.tr("\(bucketLabel) 사용량이 \(threshold)%를 넘었습니다.", "\(bucketLabel) usage exceeded \(threshold)%.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - File Watcher (auth.json change detection)

    private func startFileWatcher() {
        stopFileWatcher()
        let path = CodexAuthReader.authFilePath
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        // Set cancel handler first to ensure fd is always closed,
        // even if we bail out before resume().
        source.setCancelHandler {
            close(fd)
        }

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Token was refreshed — reset failures and retry immediately
                self.consecutiveFailures = 0
                self.lastError = nil

                // If polling was in a long backoff, restart it
                if self.pollingTask == nil || CodexAuthReader.isAvailable != self.isAvailable {
                    self.isAvailable = CodexAuthReader.isAvailable
                    if self.isAvailable && self.pollingTask == nil {
                        self.startPolling()
                        return
                    }
                }

                await self.pollOnce()
            }
        }

        source.resume()
        fileWatcher = source
    }

    private func stopFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        if consecutiveFailures > 0 {
            // Exponential backoff: 30s, 60s, 120s, max 300s
            return min(30 * pow(2, Double(consecutiveFailures - 1)), 300)
        }
        if let usage = currentUsage,
           let primary = usage.rateLimit.primaryWindow,
           primary.usedPercent > 75 {
            return 120
        }
        if aggregator.tokensPerMinute > 0 {
            return 180
        }
        return 300
    }
}
