import Foundation

// MARK: - Claude Usage Domain Models

struct ClaudeUsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    var maxUtilization: Double {
        [fiveHour?.utilization, sevenDay?.utilization, sevenDaySonnet?.utilization]
            .compactMap { $0 }.max() ?? 0
    }
}

struct UsageBucket: Codable {
    let utilization: Double   // 0-100
    let resetsAt: String?     // ISO 8601, null when unused

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }

    var timeUntilReset: TimeInterval? {
        guard let reset = resetDate else { return nil }
        return reset.timeIntervalSinceNow
    }

    @MainActor var resetCountdown: String {
        guard let remaining = timeUntilReset, remaining > 0 else { return L.usage.resetSoon }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return L.usage.countdown(days: days, hours: hours % 24)
        } else if hours > 0 {
            return L.usage.countdownHours(hours: hours, minutes: minutes)
        } else {
            return L.usage.countdownMinutes(minutes)
        }
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool
    enum CodingKeys: String, CodingKey { case isEnabled = "is_enabled" }
}

// MARK: - Claude Usage Monitor

/// Adaptive polling monitor for Claude usage/rate-limit data.
/// Reads authentication from Claude Code's Keychain entry.
@MainActor
@Observable
final class ClaudeUsageMonitor {
    private(set) var currentUsage: ClaudeUsageResponse?
    private(set) var lastError: String?
    private(set) var isAvailable: Bool = false
    /// true = logged in previously but the Keychain token is expired/unreadable
    /// (re-login required). Drives a fast poll interval so re-login is caught quickly.
    private(set) var isAuthMissing: Bool = false
    var isPolling: Bool { pollingTask != nil }
    var isInBackoff: Bool { consecutiveFailures > 0 }
    /// true = a daemon answered but predates the WINDOWS command (or has window
    /// tracking disabled). Live data still flows via the legacy direct path;
    /// the UI can hint that updating toki unifies collection in the daemon.
    private(set) var daemonUnsupported: Bool = false

    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var pollingTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    /// The last Keychain read failed transiently (not "logged out"). Drives a
    /// fast retry without wiping usage or showing the re-login prompt.
    private var authReadUnreadable = false
    /// Bumped on every (re)start. The Keychain read (`withCheckedContinuation`
    /// around a subprocess) is not cancellation-aware, so a stopped/restarted
    /// loop can resume mid-poll after its subprocess returns; the generation
    /// check makes such a stale loop bail out instead of mutating shared state
    /// or clobbering the newer loop's `sleepTask`.
    private var pollGeneration = 0

    init(aggregator: TokenAggregator, settings: AppSettings) {
        self.aggregator = aggregator
        self.settings = settings
    }

    // MARK: - Start/Stop

    func startPolling() {
        stopPolling()
        pollGeneration += 1
        let generation = pollGeneration
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.pollGeneration else { return }
                await self.pollOnce(generation: generation)
                // A concurrent stop/restart supersedes this loop — bail before
                // clobbering the newer loop's sleepTask.
                guard generation == self.pollGeneration, !Task.isCancelled else { return }
                let interval = self.computeInterval()
                self.sleepTask = Task {
                    try? await Task.sleep(for: .seconds(interval))
                }
                await self.sleepTask?.value
                self.sleepTask = nil
            }
        }
    }

    func stopPolling() {
        sleepTask?.cancel()
        sleepTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 현재 sleep 중이면 즉시 중단하고 다음 poll을 앞당깁니다.
    func wakeForImmediatePoll() {
        guard pollingTask != nil else { return }
        // A token-flow wake implies possible re-login: ask the daemon for a
        // forced revalidation (max_age=0) on the poll this wake triggers.
        forceFreshNext = true
        sleepTask?.cancel()
    }

    /// Next daemon fetch must revalidate (set by wakeForImmediatePoll).
    private var forceFreshNext = false

    // MARK: - Polling

    private func pollOnce(generation: Int) async {
        // Daemon-first: the daemon owns Claude window collection (single
        // poller, single call budget, works while this app is closed). The
        // direct Keychain+HTTP path below survives as the fallback for old
        // daemons and daemon-down, re-detected every tick.
        let maxAge: Int64 = forceFreshNext ? 0 : 120_000
        forceFreshNext = false
        let daemonResult = await TokiWindowsClient.fetch(maxAgeMs: maxAge)
        guard generation == pollGeneration, !Task.isCancelled else { return }
        switch daemonResult {
        case .success(let resp):
            daemonUnsupported = false
            let nowMs = resp.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            if let entry = resp.providers?["claude_code"],
               applyDaemonEntry(entry, nowMs: nowMs) {
                return
            }
            // No claude entry / daemon can't serve live state → legacy path.
        case .unsupported:
            daemonUnsupported = true
        case .daemonDown:
            break
        }

        // Single off-main Keychain read → availability, token validity, and
        // transient-failure status, all from one invocation.
        let result = await ClaudeAuthReader.read()
        // The read isn't cancellation-aware; if we were superseded while it ran,
        // drop the result without touching shared state.
        guard generation == pollGeneration, !Task.isCancelled else { return }
        let token: String
        switch result {
        case .credentials(let validToken):
            authReadUnreadable = false
            isAvailable = true
            isAuthMissing = false
            token = validToken
        case .expired:
            // Logged in before but token expired/empty → surface re-login.
            authReadUnreadable = false
            isAvailable = true
            currentUsage = nil
            consecutiveFailures = 0
            isAuthMissing = true
            lastError = L.tr("Claude 재로그인 필요", "Claude re-login required")
            return
        case .missing:
            // Never logged in → not available, no prompt.
            authReadUnreadable = false
            isAvailable = false
            currentUsage = nil
            consecutiveFailures = 0
            isAuthMissing = false
            lastError = nil
            return
        case .unreadable(let reason):
            // Transient read failure — keep prior usage/state, retry fast, no
            // prompt. Do NOT touch isAvailable/isAuthMissing/currentUsage.
            authReadUnreadable = true
            print("[ClaudeUsageMonitor] Keychain read unreadable, keeping prior state: \(reason)")
            return
        }

        do {
            let usage = try await ClaudeUsageClient.fetchUsage(accessToken: token)
            guard generation == pollGeneration, !Task.isCancelled else { return }
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            settings.claudeHasSevenDaySonnet = (usage.sevenDaySonnet != nil)
            checkThresholds(usage)
        } catch let error as OAuthError {
            if case .usageFetchFailed(401) = error {
                handleAuthRejected()
            } else if case .usageFetchFailed(403) = error {
                handleAuthRejected()
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

    /// Apply a daemon WINDOWS entry to this monitor's state machine. Returns
    /// false when the daemon cannot serve live Claude state (polling disabled,
    /// or no data yet) so the caller falls through to the direct path.
    /// The auth_status mapping mirrors ClaudeAuthReader's classification
    /// exactly — the UI state machine (isAuthMissing / isAvailable / lastError)
    /// is preserved, just fed from daemon-sourced values.
    private func applyDaemonEntry(_ entry: WindowsProviderEntry, nowMs: Int64) -> Bool {
        guard entry.pollingEnabled == true else { return false }

        switch entry.authStatus {
        case "ok":
            break
        case "expired":
            authReadUnreadable = false
            isAvailable = true
            currentUsage = nil
            consecutiveFailures = 0
            isAuthMissing = true
            lastError = L.tr("Claude 재로그인 필요", "Claude re-login required")
            return true
        case "missing":
            authReadUnreadable = false
            isAvailable = false
            currentUsage = nil
            consecutiveFailures = 0
            isAuthMissing = false
            lastError = nil
            return true
        default: // "unreadable" — keep prior state, retry fast (same as legacy)
            authReadUnreadable = true
            return true
        }

        let open = entry.windows.filter { $0.isOpen(nowMs: nowMs) }
        // Auth is fine but the daemon has neither polled nor stored anything —
        // a just-started daemon. Let the direct path cover this tick.
        if open.isEmpty && (entry.lastSuccessMs ?? 0) == 0 {
            return false
        }

        func bucket(_ limitId: String) -> UsageBucket? {
            open.first { $0.limitId == limitId }.map {
                UsageBucket(
                    utilization: $0.livePct,
                    resetsAt: Self.isoString(fromMs: $0.rawResetsAtMs)
                )
            }
        }
        let usage = ClaudeUsageResponse(
            fiveHour: bucket("five_hour"),
            sevenDay: bucket("seven_day"),
            sevenDaySonnet: bucket("seven_day_sonnet"),
            extraUsage: entry.extraUsageEnabled.map { ExtraUsage(isEnabled: $0) }
        )
        authReadUnreadable = false
        isAvailable = true
        isAuthMissing = false
        currentUsage = usage
        lastError = nil
        consecutiveFailures = 0
        settings.claudeHasSevenDaySonnet = (usage.sevenDaySonnet != nil)
        checkThresholds(usage)
        return true
    }

    private static func isoString(fromMs ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The server rejected a token that looked locally valid (revoked, or an
    /// expiry we couldn't see). Mirror the Codex auth-error path: clear usage,
    /// show the re-login state, and drop to the fast (~20s) retry interval.
    private func handleAuthRejected() {
        currentUsage = nil
        isAuthMissing = true
        consecutiveFailures = 0
        lastError = L.tr("Claude 재로그인 필요", "Claude re-login required")
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        // Transient Keychain read failure: retry soon to recover, don't back off.
        if authReadUnreadable { return 20 }
        if !isAvailable { return 60 }
        // Token expired or server-rejected: poll fast so re-login is picked up
        // within ~20s even if no tokens are flowing (the token-activity wake
        // handles the flowing case).
        if isAuthMissing { return 20 }
        // Backoff capped at 60s: recovers within 1 minute after transient server errors
        if consecutiveFailures > 0 {
            return min(15 * pow(2, Double(consecutiveFailures - 1)), 60)
        }
        if currentUsage == nil { return 15 }
        // High utilization or heavy token flow → poll aggressively
        if let usage = currentUsage, usage.maxUtilization > 75 { return 60 }
        if aggregator.tokensPerMinute > 5000 { return 60 }
        if aggregator.tokensPerMinute > 0 { return 120 }
        return 300
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: ClaudeUsageResponse) {
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .claudeFiveHour,       utilization: usage.fiveHour?.utilization,       resetId: usage.fiveHour?.resetsAt),
            .init(bucket: .claudeSevenDay,       utilization: usage.sevenDay?.utilization,       resetId: usage.sevenDay?.resetsAt),
            .init(bucket: .claudeSevenDaySonnet, utilization: usage.sevenDaySonnet?.utilization, resetId: usage.sevenDaySonnet?.resetsAt),
        ], providerTitle: L.panel.claudeUsage, settings: settings)
    }
}
