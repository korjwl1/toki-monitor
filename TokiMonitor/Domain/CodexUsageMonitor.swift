import Foundation

/// Polls Codex (OpenAI) usage/rate-limit data from ChatGPT backend API.
/// Reads OAuth token from ~/.codex/auth.json (written by Codex CLI login).
@MainActor
@Observable
final class CodexUsageMonitor {
    private(set) var currentUsage: CodexUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false

    private var pollingTask: Task<Void, Never>?
    private let aggregator: TokenAggregator
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5

    init(aggregator: TokenAggregator) {
        self.aggregator = aggregator
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
        // Re-check availability (user might delete auth.json)
        guard CodexAuthReader.isAvailable else {
            isAvailable = false
            currentUsage = nil
            return
        }

        do {
            let token = try CodexAuthReader.readAccessToken()
            let usage = try await CodexUsageClient.fetchUsage(accessToken: token)
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
        } catch let error as CodexAuthError {
            switch error {
            case .fetchFailed(401), .fetchFailed(403):
                // Might be transient — only show error after 3 consecutive failures
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
                }
            case .fetchFailed(429):
                // Rate limited — back off silently
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

        // Stop polling after too many consecutive failures
        if consecutiveFailures >= maxConsecutiveFailures {
            lastError = L.tr("Codex 사용량 조회 실패 — 폴링 중단", "Codex usage check failed — polling stopped")
            stopPolling()
        }
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        // Codex usage API rate limits are unknown — be conservative
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
