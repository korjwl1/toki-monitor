import Foundation

// MARK: - Claude Usage Domain Models

struct ClaudeUsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    /// Which model the scoped weekly limit belongs to ("Fable", "Sonnet", ...).
    /// Not on the wire — derived from the limit id, so it is decoded as nil
    /// and filled in by the daemon path.
    var scopedWeeklyLabel: String? = nil
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

    /// ISO8601DateFormatter is documented thread-safe; creating one per access
    /// is the expensive part (this sits on the menu-render path).
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Self.fractionalFormatter.date(from: resetsAt)
            ?? Self.plainFormatter.date(from: resetsAt)
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

/// Labels for a model-scoped weekly limit. Free functions rather than members
/// of the @MainActor monitor: they are pure string formatting with no monitor
/// state, and hanging them off an actor-isolated type made them unusable from
/// tests (and needlessly actor-hopped at the call site).
enum ScopedWeeklyLabel {
    /// "weekly_fable" + 10080 -> "Fable 7일". The daemon lowercases the model's
    /// display name into the limit id (that is what makes the id stable as a
    /// storage key), so the UI title-cases it back and appends the span the row
    /// actually carries — a hardcoded "7일" would silently lie if the endpoint
    /// ever scoped a limit to a different window length.
    static func make(model limitId: String, windowMinutes: Int) -> String {
        let raw = limitId == "seven_day_sonnet"
            ? "sonnet"
            : (limitId.hasPrefix("weekly_")
                ? String(limitId.dropFirst("weekly_".count))
                : limitId)
        let name = raw.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return "\(name) \(span(minutes: windowMinutes))"
    }

    static func span(minutes: Int) -> String {
        if minutes % 1440 == 0 && minutes >= 1440 {
            let d = minutes / 1440
            return L.tr("\(d)일", "\(d)d")
        }
        if minutes % 60 == 0 {
            let h = minutes / 60
            return L.tr("\(h)시간", "\(h)h")
        }
        return L.tr("\(minutes)분", "\(minutes)m")
    }
}

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
        // forced revalidation (max_age=0) on the poll this wake triggers, and
        // give a rejected token a real retry (tokens flowing is itself evidence
        // the credential works).
        forceFreshNext = true
        directAuthRejected = false
        sleepTask?.cancel()
    }

    /// Next daemon fetch must revalidate (set by wakeForImmediatePoll).
    private var forceFreshNext = false
    /// Last time a stale-row synthesis routed a direct probe (≤2/hour).
    private var lastStaleDirectProbe: Date = .distantPast

    // MARK: - Polling

    private func pollOnce(generation: Int) async {
        // Daemon-first: the daemon owns Claude window collection (single
        // poller, single call budget, works while this app is closed). The
        // direct Keychain+HTTP path below survives as the fallback for old
        // daemons and daemon-down, re-detected every tick.
        // Freshness is only requested while tokens flow (or on a wake):
        // passing max_age while idle re-armed the daemon's refresh path every
        // poll and had it hitting the Claude API ~every 5 minutes on a fully
        // idle machine — defeating the activity gate ("idle 비용 0"). Idle
        // reads serve the cached rows; resets still surface via finalize +
        // the zero-bucket synthesis below.
        let tokensActive = aggregator.tokensPerMinute > 0
        let maxAge: Int64? = forceFreshNext ? 0 : (tokensActive ? 120_000 : nil)
        forceFreshNext = false
        let daemonResult = await TokiWindowsClient.fetch(maxAgeMs: maxAge)
        guard generation == pollGeneration, !Task.isCancelled else { return }
        switch daemonResult {
        case .success(let resp):
            daemonUnsupported = false
            let nowMs = resp.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            if let entry = resp.providers?["claude_code"],
               applyDaemonEntry(entry, nowMs: nowMs) {
                // The daemon served stale data and is refreshing in the
                // background — follow up shortly instead of sleeping minutes.
                if resp.refreshing == true { retryShortlyOnce = true }
                return
            }
            // No claude entry / daemon can't serve live state → legacy path.
        case .unsupported:
            daemonUnsupported = true
        case .unavailable:
            daemonUnsupported = false
        case .daemonDown:
            // No daemon at all: the update hint would be misleading.
            daemonUnsupported = false
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
            directAuthRejected = false
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

    /// KEEP IN SYNC with the legacy switch in pollOnce below: the two paths
    /// consume different shapes (wire string vs ClaudeAuthResult) but must
    /// drive the SAME state machine — drift here already produced a real bug
    /// in the Codex twin (expired silently swallowed).
    /// Apply a daemon WINDOWS entry to this monitor's state machine. Returns
    /// false when the daemon cannot serve live Claude state (polling disabled,
    /// or no data yet) so the caller falls through to the direct path.
    /// The auth_status mapping mirrors ClaudeAuthReader's classification
    /// exactly — the UI state machine (isAuthMissing / isAvailable / lastError)
    /// is preserved, just fed from daemon-sourced values.
    private func applyDaemonEntry(_ entry: WindowsProviderEntry, nowMs: Int64) -> Bool {
        guard entry.pollingEnabled == true else { return false }
        // A failed keyspace scan arrives as `windows: []` plus an error. Taking
        // that as "no windows yet" would synthesize 0%% buckets and paint a full
        // quota bar over a broken read.
        if entry.error != nil { return false }


        switch entry.authStatus {
        case "ok":
            // A direct 401/403 is the ONLY detector for a server-revoked token:
            // the daemon classifies auth from Keychain presence and keeps
            // saying "ok", so its verdict must not overwrite ours. Answered
            // HERE rather than by falling through to the direct path — that
            // would poll a dead token over HTTP every 20s forever.
            if directAuthRejected {
                authReadUnreadable = false
                isAvailable = true
                currentUsage = nil
                consecutiveFailures = 0
                isAuthMissing = true
                lastError = L.tr("Claude 재로그인 필요", "Claude re-login required")
                return true
            }
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
        default:
            // "unreadable" — the daemon could not classify (its own 30s cache
            // may hold that state). Fall THROUGH to the direct read instead of
            // pinning the widget: the local read either succeeds (self-heal)
            // or sets the same state itself.
            return false
        }

        var open = entry.windows.filter { $0.isOpen(nowMs: nowMs) }
        // Ignore rows still open under a previous login: they linger until
        // their own reset. Filtered UNCONDITIONALLY when the daemon reports an
        // account — requiring the new account to already have a row disabled
        // the filter in exactly the switch window it exists for.
        let preFilterCount = open.count
        if let current = entry.currentAccount, !current.isEmpty {
            open = open.filter { $0.account == current }
        }
        // Everything belonged to a superseded login: that is "we have no data
        // for the current account", NOT "the windows reset to 0%".
        if preFilterCount > 0 && open.isEmpty {
            return false
        }
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
        // Staleness gate — but ONLY where it matters, and throttled.
        //
        // last_success_ms is the daemon poller's own last API call, and the
        // poller is activity-gated: on an idle machine it freezes ~30min after
        // the last token. An unconditional gate therefore returned false on
        // EVERY tick forever, sending this app back to the direct Keychain+HTTP
        // path every 300s — exactly the idle-polling leak this branch removed,
        // re-introduced one layer up.
        //
        // Fresh open rows need no gate at all (they carry their own state).
        // Only a SYNTHESIZED zero is a claim about data we don't have, so gate
        // that case, and throttle the resulting direct probe like the Codex
        // twin does (≤2/hour).
        let needsSynthesis = !open.contains { $0.limitId == "five_hour" }
            || !open.contains { $0.limitId == "seven_day" }
        let lastSuccess = entry.lastSuccessMs ?? 0
        if needsSynthesis, nowMs - lastSuccess > 30 * 60_000,
           Date().timeIntervalSince(lastStaleDirectProbe) > 30 * 60 {
            lastStaleDirectProbe = Date()
            return false
        }
        // No open row for a standard limit + auth ok ⇒ the window genuinely
        // reset (or was never used): that is 0%, matching the legacy API's
        // idle shape (utilization 0, resets_at null). Leaving it nil hid the
        // HP bar and froze the last pre-reset percentage on screen.
        func bucketOrZero(_ limitId: String) -> UsageBucket {
            bucket(limitId) ?? UsageBucket(utilization: 0, resetsAt: nil)
        }
        // The scoped-weekly slot takes ANY model-scoped weekly limit, not
        // just Sonnet. The endpoint moved these into its `limits[]` array
        // keyed by model, so the daemon records them as `weekly_<model>` —
        // `seven_day_sonnet` returns null on accounts whose scoped limit is a
        // different model, and matching that literal key alone made a limit
        // the user is actively consuming invisible.
        let scopedWeekly = open.first { row in
            row.limitId == "seven_day_sonnet" || row.limitId.hasPrefix("weekly_")
        }
        let usage = ClaudeUsageResponse(
            fiveHour: bucketOrZero("five_hour"),
            sevenDay: bucketOrZero("seven_day"),
            sevenDaySonnet: scopedWeekly.map {
                UsageBucket(utilization: $0.livePct,
                            resetsAt: Self.isoString(fromMs: $0.rawResetsAtMs))
            },
            scopedWeeklyLabel: scopedWeekly.map {
                ScopedWeeklyLabel.make(model: $0.limitId, windowMinutes: $0.windowMinutes)
            },
            extraUsage: entry.extraUsageEnabled.map { ExtraUsage(isEnabled: $0) }
        )
        authReadUnreadable = false
        isAvailable = true
        isAuthMissing = false
        currentUsage = usage
        lastError = nil
        consecutiveFailures = 0
        // Set-true-only: an idle machine past a weekly reset has no open
        // scoped row, and clearing the flag would make the bar and its
        // settings toggles disappear and reappear with usage.
        if usage.sevenDaySonnet != nil {
            settings.claudeHasSevenDaySonnet = true
            if let label = usage.scopedWeeklyLabel {
                settings.claudeScopedWeeklyLabel = label
            }
        }
        checkThresholds(usage)
        return true
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // Fractional seconds so UsageBucket.resetDate's FIRST parser accepts
        // daemon-sourced strings (plain form made every parse fail once).
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func isoString(fromMs ms: Int64) -> String {
        isoFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The server rejected a token that looked locally valid (revoked, or an
    /// expiry we couldn't see). Mirror the Codex auth-error path: clear usage,
    /// show the re-login state, and drop to the fast (~20s) retry interval.
    private func handleAuthRejected() {
        currentUsage = nil
        isAuthMissing = true
        consecutiveFailures = 0
        directAuthRejected = true
        lastError = L.tr("Claude 재로그인 필요", "Claude re-login required")
    }

    /// Sticky until a direct fetch succeeds: the daemon cannot see a 401 (it
    /// classifies auth from Keychain presence), so it would otherwise overwrite
    /// this on its very next tick. Cleared only by evidence to the contrary.
    private var directAuthRejected: Bool = false

    // MARK: - Adaptive Interval

    /// One-shot short retry after a daemon `refreshing:true` response.
    private var retryShortlyOnce = false

    private func computeInterval() -> TimeInterval {
        if retryShortlyOnce {
            retryShortlyOnce = false
            return 3
        }
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
        // resetId normalized to epoch seconds: the raw ISO string differs
        // between the legacy API (microseconds) and the daemon path, and a
        // source flip mid-window must not re-fire already-sent alerts.
        func resetId(_ bucket: UsageBucket?) -> String? {
            guard let bucket else { return nil }
            if let date = bucket.resetDate {
                return String(Int(date.timeIntervalSince1970))
            }
            return bucket.resetsAt
        }
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .claudeFiveHour,       utilization: usage.fiveHour?.utilization,       resetId: resetId(usage.fiveHour)),
            .init(bucket: .claudeSevenDay,       utilization: usage.sevenDay?.utilization,       resetId: resetId(usage.sevenDay)),
            .init(bucket: .claudeSevenDaySonnet, utilization: usage.sevenDaySonnet?.utilization, resetId: resetId(usage.sevenDaySonnet)),
        ], providerTitle: L.panel.claudeUsage, settings: settings)
    }
}
