import Foundation

// MARK: - Codex Usage Domain Models

struct CodexUsageResponse: Codable {
    let planType: String
    let rateLimit: CodexRateLimit
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

struct CodexRateLimit: Codable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct CodexUsageWindow: Codable {
    let usedPercent: Int
    let limitWindowSeconds: Int
    let resetAfterSeconds: Int
    let resetAt: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    var resetCountdown: String {
        let totalHours = resetAfterSeconds / 3600
        let m = (resetAfterSeconds % 3600) / 60
        if totalHours >= 24 {
            let d = totalHours / 24
            return L.tr("\(d)일 \(totalHours % 24)시간", "\(d)d \(totalHours % 24)h")
        }
        if totalHours > 0 { return L.tr("\(totalHours)시간 \(m)분", "\(totalHours)h \(m)m") }
        return L.tr("\(m)분", "\(m)m")
    }

    var windowLabel: String {
        let hours = limitWindowSeconds / 3600
        if hours >= 24 { return L.tr("\(hours / 24)일", "\(hours / 24)d") }
        return L.tr("\(hours)시간", "\(hours)h")
    }
}

struct CodexCredits: Codable {
    let hasCredits: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try container.decode(Bool.self, forKey: .hasCredits)
        if let d = try? container.decode(Double.self, forKey: .balance) {
            balance = d
        } else if let s = try? container.decode(String.self, forKey: .balance) {
            balance = Double(s)
        } else {
            balance = nil
        }
    }
}

// MARK: - Codex Usage Monitor

/// Polls Codex (OpenAI) usage/rate-limit data from ChatGPT backend API.
/// Reads OAuth token from ~/.codex/auth.json (written by Codex CLI login).
/// Watches auth.json for changes via DispatchSource to recover from token expiry.
@MainActor
@Observable
final class CodexUsageMonitor {
    private(set) var currentUsage: CodexUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false
    var isPolling: Bool { pollingTask != nil }

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
            case .authFileNotFound:
                isAvailable = false
                currentUsage = nil
                lastError = nil
            case .tokenMissing:
                // 파일은 있지만 토큰을 읽을 수 없음 → 로그인 화면 대신 에러 표시
                lastError = L.tr("Codex 인증 정보를 읽을 수 없습니다", "Could not read Codex auth token")
                consecutiveFailures += 1
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
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .codexPrimary,   utilization: usage.rateLimit.primaryWindow.map   { Double($0.usedPercent) }, resetId: usage.rateLimit.primaryWindow.map   { String($0.resetAt) } ?? "unknown"),
            .init(bucket: .codexSecondary, utilization: usage.rateLimit.secondaryWindow.map { Double($0.usedPercent) }, resetId: usage.rateLimit.secondaryWindow.map { String($0.resetAt) } ?? "unknown"),
        ], providerTitle: L.tr("Codex 사용량", "Codex Usage"), settings: settings)
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
