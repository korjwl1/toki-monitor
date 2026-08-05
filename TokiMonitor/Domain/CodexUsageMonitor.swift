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

    /// `primary`/`secondary` are kind SLOTS in the API, not roles: a
    /// weekly-first plan (`prolite`) reports the 7-day window as `primary` and
    /// the 5-hour as `secondary`. Consumers treat primary=session and
    /// secondary=weekly (which is what the daemon path builds), so the direct
    /// path normalizes to the same convention — otherwise the HP bar showed the
    /// 5-hour window under the "Codex 7일" label, and the same window raised
    /// alerts under two different bucket keys depending on which path served it.
    func normalizedBySpan() -> CodexRateLimit {
        guard let p = primaryWindow, let s = secondaryWindow,
              p.limitWindowSeconds > s.limitWindowSeconds else { return self }
        return CodexRateLimit(
            allowed: allowed,
            limitReached: limitReached,
            primaryWindow: s,
            secondaryWindow: p
        )
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
        // A synthesized window (closed session, real reset unknown) carries
        // resetAt == 0; rendering "0분" would assert a reset that isn't known.
        if resetAt == 0 { return L.tr("초기화됨", "reset") }
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
    /// true = 일시적 서버 오류로 backoff 중. 인증 오류(401/403)는 포함하지 않음 — 재시도해도 의미 없음.
    var isInTransientBackoff: Bool { consecutiveFailures > 0 && !isAuthError }
    private(set) var isAuthError: Bool = false
    /// Sticky until a direct fetch succeeds: the daemon classifies Codex auth
    /// purely from auth.json presence and never sees a 401, so it would clear
    /// this on its next tick. Cleared only by evidence to the contrary.
    private var directAuthRejected: Bool = false
    /// true = a daemon answered but predates the WINDOWS command.
    private(set) var daemonUnsupported: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private let aggregator: TokenAggregator
    private let settings: AppSettings
    private var consecutiveFailures = 0
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var rearmTask: Task<Void, Never>?
    /// Bumped on every (re)start. The usage fetch awaits a non-cancellation-aware
    /// URLSession call, so a stopped/restarted loop can resume mid-poll after the
    /// request returns; the generation check makes such a stale loop bail out
    /// instead of mutating shared state or clobbering the newer loop's `sleepTask`.
    private var pollGeneration = 0

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
        rearmTask?.cancel()
        rearmTask = nil
        stopFileWatcher()
    }

    /// 현재 sleep 중이면 즉시 중단하고 다음 poll을 앞당깁니다.
    func wakeForImmediatePoll() {
        guard pollingTask != nil else { return }
        // The auth.json watcher fires this on any credential change, so a
        // re-login gets a real retry instead of being blocked by the sticky
        // rejection from the previous token.
        directAuthRejected = false
        sleepTask?.cancel()
    }

    // MARK: - Polling

    private func pollOnce(generation: Int) async {
        // Daemon-first: Codex windows are extracted passively from rollout
        // files the daemon already watches — zero API calls. The direct
        // wham/usage path below remains for old daemons, daemon-down, and the
        // idle case (no open window rows to display).
        // Always nil: the daemon's max_age join drives the CLAUDE poller only
        // (Codex rows are passive rollout-file extraction), so asking for
        // freshness here bought nothing and forced Claude API calls at 120s
        // even while the Claude widget was hidden.
        let daemonResult = await TokiWindowsClient.fetch(maxAgeMs: nil)
        guard generation == pollGeneration, !Task.isCancelled else { return }
        switch daemonResult {
        case .success(let resp):
            daemonUnsupported = false
            let nowMs = resp.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            if let entry = resp.providers?["codex"],
               applyDaemonEntry(entry, nowMs: nowMs) {
                // NOTE: resp.refreshing is a CLAUDE-poller signal (the
                // daemon's bounded revalidation timed out); Codex is passive
                // file extraction — reacting here put this monitor into a 3s
                // poll loop whenever the Claude poller was slow.
                return
            }
        case .unsupported:
            daemonUnsupported = true
        case .unavailable:
            daemonUnsupported = false
        case .daemonDown:
            daemonUnsupported = false
        }

        // Re-check availability (user might delete auth.json)
        guard CodexAuthReader.isAvailable else {
            isAvailable = false
            currentUsage = nil
            return
        }
        // Re-arm the watcher if a prior delete tore it down and it never came back.
        ensureWatcherArmed()

        do {
            let token = try CodexAuthReader.readAccessToken()
            let accountId = CodexAuthReader.readAccountId()
            let raw = try await CodexUsageClient.fetchUsage(accessToken: token, accountId: accountId)
            guard generation == pollGeneration, !Task.isCancelled else { return }
            // Normalize ONCE, before anything reads the slots — the alert
            // buckets below key off primary/secondary too.
            let usage = CodexUsageResponse(
                planType: raw.planType,
                rateLimit: raw.rateLimit.normalizedBySpan(),
                credits: raw.credits
            )
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            isAuthError = false
            directAuthRejected = false
            settings.codexHasSecondaryWindow = (usage.rateLimit.secondaryWindow != nil)
            checkThresholds(usage)
        } catch let error as CodexAuthError {
            switch error {
            case .fetchFailed(401), .fetchFailed(403):
                // Surface immediately, like the Claude twin. The >= 3 counter
                // could never be reached here: probes are 30 minutes apart and
                // every daemon tick in between reset it to 0, so a revoked
                // token showed frozen usage forever instead of a re-login
                // notice. (KEEP IN SYNC with ClaudeUsageMonitor.)
                isAuthError = true
                directAuthRejected = true
                currentUsage = nil
                consecutiveFailures = 0
                lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
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

    /// Last time the direct (wham) path ran while daemon rows were stale —
    /// bounds the fallback probes to ~2/hour during idle.
    private var lastStaleDirectProbe: Date = .distantPast

    /// Apply a daemon WINDOWS entry. Returns false when the daemon has nothing
    /// live to show (no open rows — e.g. idle: passive extraction has no rows
    /// until usage flows), or when its rows are STALE and a direct probe is
    /// due: Codex auth expiry is invisible to the daemon (auth.json carries
    /// no expiry; the passive path never gets a 401), so an open weekly row
    /// could mask a dead login for up to 7 days. The occasional direct call
    /// is the only 401 detector.
    private func applyDaemonEntry(_ entry: WindowsProviderEntry, nowMs: Int64) -> Bool {
        // A failed keyspace scan arrives as `windows: []` plus an error. Taking
        // that as "no windows yet" would paint a full quota bar over a broken read.
        if entry.error != nil { return false }
        switch entry.authStatus {
        case "ok":
            // The daemon's classification is a 30s cache; auth.json is a local
            // file we can stat right now. A logout would otherwise reappear as
            // "available with stale usage" for up to 30s.
            guard CodexAuthReader.isAvailable else { return false }
            // A direct 401/403 is the ONLY detector for a server-revoked token:
            // the daemon classifies Codex auth from auth.json presence and keeps
            // saying "ok", so its verdict must not overwrite ours. Answered HERE
            // rather than by falling through to the direct path — that would
            // poll a dead token over HTTP every 15s forever.
            if directAuthRejected {
                currentUsage = nil
                consecutiveFailures = 0
                isAuthError = true
                lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
                return true
            }
        case "missing":
            // Same in reverse: after a login the cached "missing" would hide
            // the freshly-available widget for another cache generation.
            guard !CodexAuthReader.isAvailable else { return false }
            isAvailable = false
            currentUsage = nil
            lastError = nil
            return true
        case "expired":
            // Mirror the legacy 401 path: surface re-login instead of freezing
            // stale usage forever. currentUsage MUST be cleared — the menu
            // renders the usage widget whenever it is non-nil, so leaving it
            // would keep showing stale numbers and never the re-login notice.
            isAvailable = true
            isAuthError = true
            currentUsage = nil
            lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
            return true
        default:
            // unreadable — fall through to the direct path (see Claude twin).
            return false
        }

        var open = entry.windows.filter { $0.isOpen(nowMs: nowMs) }
        // Ignore rows still open under a previous login (see the Claude twin):
        // filtered unconditionally when the daemon reports an account.
        if let current = entry.currentAccount, !current.isEmpty {
            open = open.filter { $0.account == current }
        }
        guard !open.isEmpty else { return false }

        let newestObservedMs = open.map(\.observedTsMs).max() ?? 0
        let staleMs = nowMs - newestObservedMs
        if staleMs > 30 * 60_000, Date().timeIntervalSince(lastStaleDirectProbe) > 30 * 60 {
            lastStaleDirectProbe = Date()
            return false // direct path verifies the token (401 → re-login UI)
        }

        func window(_ row: WindowRow) -> CodexUsageWindow {
            let resetAt = Int(row.rawResetsAtMs / 1000)
            // Clamp before Int(): a buggy wire double must degrade, not trap.
            let pct = row.livePct.isFinite ? min(max(row.livePct, 0), 999) : 0
            return CodexUsageWindow(
                usedPercent: Int(pct.rounded()),
                limitWindowSeconds: row.windowMinutes * 60,
                // Wall clock, not the daemon's response timestamp — a cached
                // response (max_age 120s) would overstate the countdown.
                resetAfterSeconds: max(0, resetAt - Int(Date().timeIntervalSince1970)),
                resetAt: resetAt
            )
        }
        // Map by KIND, never by presence: promoting the weekly row to primary
        // when the session window is closed (a very common idle state) fired
        // the same window's alert under two buckets and made the secondary
        // settings toggles flip on and off with usage. Among multiple limit
        // ids the main "codex" limit outranks model-specific ones.
        func pick(_ kind: String) -> WindowRow? {
            let candidates = open.filter { $0.kind == kind }
            return candidates.first { $0.limitId == "codex" } ?? candidates.first
        }
        let session = pick("session")
        let weekly = pick("weekly")
        guard session != nil || weekly != nil else { return false }

        let reached = open.contains { $0.limitReachedKind > 0 }
        // A closed session window means 0% used — but ONLY for plans that
        // actually have one. Weekly-first plans (e.g. prolite, whose primary
        // limit is 10080 minutes) would otherwise show a permanent fake
        // "5시간 · 0% · 0분" row, and the HP bar would read it as full quota.
        // entry.windows carries 8 days of history, so a session limit having
        // ever existed is an exact test.
        let hasSessionLimit = entry.windows.contains { row in
            row.kind == "session" && (entry.currentAccount.map { row.account == $0 } ?? true)
        }
        let primaryWindow: CodexUsageWindow?
        let secondaryWindow: CodexUsageWindow?
        if let session {
            primaryWindow = window(session)
            secondaryWindow = weekly.map(window)
        } else if hasSessionLimit, let weekly {
            // Session window exists for this plan but is currently closed:
            // 0% used, with the real reset instant left unknown.
            primaryWindow = CodexUsageWindow(
                usedPercent: 0,
                limitWindowSeconds: 300 * 60,
                resetAfterSeconds: 0,
                resetAt: 0
            )
            secondaryWindow = window(weekly)
        } else {
            // Weekly-only plan: the weekly limit IS the primary one (the
            // provider's own presentation).
            primaryWindow = weekly.map(window)
            secondaryWindow = nil
        }
        let usage = CodexUsageResponse(
            planType: (session ?? weekly)?.plan ?? "",
            rateLimit: CodexRateLimit(
                allowed: !reached,
                limitReached: reached,
                primaryWindow: primaryWindow,
                secondaryWindow: secondaryWindow
            ),
            credits: nil
        )
        isAvailable = true
        currentUsage = usage
        lastError = nil
        consecutiveFailures = 0
        isAuthError = false
        // Set-true-only (see the Claude Sonnet flag): an idle gap must not
        // make the secondary toggles disappear.
        if usage.rateLimit.secondaryWindow != nil {
            settings.codexHasSecondaryWindow = true
        }
        checkThresholds(usage)
        return true
    }

    // MARK: - Threshold Alerts

    private func checkThresholds(_ usage: CodexUsageResponse) {
        UsageAlertHelpers.checkThresholds([
            .init(bucket: .codexPrimary,   utilization: usage.rateLimit.primaryWindow.map   { Double($0.usedPercent) }, resetId: usage.rateLimit.primaryWindow.map   { String($0.resetAt) }),
            .init(bucket: .codexSecondary, utilization: usage.rateLimit.secondaryWindow.map { Double($0.usedPercent) }, resetId: usage.rateLimit.secondaryWindow.map { String($0.resetAt) }),
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

        source.setEventHandler { [weak self, weak source] in
            // Read the event flags synchronously (valid only inside the handler).
            let flags = source?.data ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                // logout→login deletes and recreates auth.json, so our fd points at
                // a now-stale inode and will never fire again. Tear the source down
                // immediately (closing the fd) and re-arm once the new file appears.
                // Codex's in-place refresh (write) keeps the inode, so no re-arm needed there.
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.stopFileWatcher()
                    self.rearmWatcherWhenFileReappears()
                }
                self.handleAuthFileChange()
            }
        }

        source.resume()
        fileWatcher = source
    }

    /// After the watched auth.json is deleted/replaced, wait for the new file to
    /// appear (login) and re-arm the watcher on its inode. Falls back to the normal
    /// poll cadence if the file never reappears within the window.
    private func rearmWatcherWhenFileReappears() {
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if CodexAuthReader.isAvailable {
                    self.startFileWatcher()   // re-open on the new inode
                    self.handleAuthFileChange()
                    return
                }
            }
        }
    }

    /// Common handling for any auth.json change: clear error state, sync
    /// availability, and either (re)start polling or wake the existing loop.
    private func handleAuthFileChange() {
        consecutiveFailures = 0
        isAuthError = false
        lastError = nil

        let nowAvailable = CodexAuthReader.isAvailable
        isAvailable = nowAvailable
        guard nowAvailable else {
            currentUsage = nil
            return
        }

        if pollingTask == nil {
            startPolling()
        } else {
            // Wake the polling loop instead of calling pollOnce() directly
            // to avoid a double-poll race with the main polling task.
            wakeForImmediatePoll()
        }
    }

    private func stopFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// Safety net for the case where auth.json was deleted and the re-arm window
    /// elapsed before the user logged back in: if the watcher isn't armed but the
    /// file now exists, re-arm it so later auth changes are caught promptly
    /// instead of waiting up to the idle poll interval.
    private func ensureWatcherArmed() {
        guard fileWatcher == nil, CodexAuthReader.isAvailable else { return }
        startFileWatcher()
    }

    // MARK: - Adaptive Interval

    private func computeInterval() -> TimeInterval {
        // Backoff capped at 60s: recovers within 1 minute after transient errors/auth expiry
        if consecutiveFailures > 0 {
            return min(30 * pow(2, Double(consecutiveFailures - 1)), 60)
        }
        // Revoked token: `currentUsage == nil` would otherwise ask for a 15s
        // retry loop, but nothing changes until the user re-logs in — and the
        // auth.json watcher wakes us the moment they do.
        if directAuthRejected { return 60 }
        if currentUsage == nil { return 15 }
        // High utilization or heavy token flow → poll aggressively
        if let usage = currentUsage,
           let primary = usage.rateLimit.primaryWindow,
           primary.usedPercent > 75 { return 60 }
        if aggregator.tokensPerMinute > 5000 { return 60 }
        if aggregator.tokensPerMinute > 0 { return 120 }
        return 300
    }
}
