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
    /// true = 일시적 서버 오류로 backoff 중. 인증 오류(401/403)는 포함하지 않음 — 재시도해도 의미 없음.
    var isInTransientBackoff: Bool { consecutiveFailures > 0 && !isAuthError }
    private(set) var isAuthError: Bool = false
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
        sleepTask?.cancel()
    }

    // MARK: - Polling

    private func pollOnce(generation: Int) async {
        // Daemon-first: Codex windows are extracted passively from rollout
        // files the daemon already watches — zero API calls. The direct
        // wham/usage path below remains for old daemons, daemon-down, and the
        // idle case (no open window rows to display).
        let daemonResult = await TokiWindowsClient.fetch(maxAgeMs: 120_000)
        guard generation == pollGeneration, !Task.isCancelled else { return }
        switch daemonResult {
        case .success(let resp):
            daemonUnsupported = false
            let nowMs = resp.nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            if let entry = resp.providers?["codex"],
               applyDaemonEntry(entry, nowMs: nowMs) {
                // The daemon served stale data and is refreshing in the
                // background — follow up shortly instead of sleeping minutes.
                if resp.refreshing == true { retryShortlyOnce = true }
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
            let usage = try await CodexUsageClient.fetchUsage(accessToken: token, accountId: accountId)
            guard generation == pollGeneration, !Task.isCancelled else { return }
            currentUsage = usage
            lastError = nil
            consecutiveFailures = 0
            isAuthError = false
            settings.codexHasSecondaryWindow = (usage.rateLimit.secondaryWindow != nil)
            checkThresholds(usage)
        } catch let error as CodexAuthError {
            switch error {
            case .fetchFailed(401), .fetchFailed(403):
                isAuthError = true
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

    /// Apply a daemon WINDOWS entry. Returns false when the daemon has nothing
    /// live to show (no open rows — e.g. idle: passive extraction has no rows
    /// until usage flows), letting the direct path serve that tick.
    private func applyDaemonEntry(_ entry: WindowsProviderEntry, nowMs: Int64) -> Bool {
        switch entry.authStatus {
        case "ok":
            break
        case "missing":
            isAvailable = false
            currentUsage = nil
            lastError = nil
            return true
        case "expired":
            // Mirror the legacy 401 path: surface re-login instead of freezing
            // stale usage forever (the daemon path must not swallow this).
            isAvailable = true
            isAuthError = true
            lastError = L.tr("Codex 재로그인 필요", "Codex re-login required")
            return true
        default: // unreadable — keep prior state
            return true
        }

        let open = entry.windows.filter { $0.isOpen(nowMs: nowMs) }
        guard !open.isEmpty else { return false }

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
        // Session-length window → primary, weekly → secondary; plans with only
        // a weekly limit (e.g. prolite) surface it as primary. Among multiple
        // limit ids the main "codex" limit outranks model-specific ones.
        func pick(_ kind: String) -> WindowRow? {
            let candidates = open.filter { $0.kind == kind }
            return candidates.first { $0.limitId == "codex" } ?? candidates.first
        }
        let session = pick("session")
        let weekly = pick("weekly")
        let primary = session ?? weekly
        let secondary = (session != nil) ? weekly : nil
        guard let primary else { return false }

        let reached = open.contains { $0.limitReachedKind > 0 }
        let usage = CodexUsageResponse(
            planType: primary.plan,
            rateLimit: CodexRateLimit(
                allowed: !reached,
                limitReached: reached,
                primaryWindow: window(primary),
                secondaryWindow: secondary.map(window)
            ),
            credits: nil
        )
        isAvailable = true
        currentUsage = usage
        lastError = nil
        consecutiveFailures = 0
        isAuthError = false
        settings.codexHasSecondaryWindow = (usage.rateLimit.secondaryWindow != nil)
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

    /// One-shot short retry after a daemon `refreshing:true` response.
    private var retryShortlyOnce = false

    private func computeInterval() -> TimeInterval {
        if retryShortlyOnce {
            retryShortlyOnce = false
            return 3
        }
        // Backoff capped at 60s: recovers within 1 minute after transient errors/auth expiry
        if consecutiveFailures > 0 {
            return min(30 * pow(2, Double(consecutiveFailures - 1)), 60)
        }
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
