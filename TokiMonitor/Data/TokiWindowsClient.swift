import Foundation

// MARK: - Window wire models (daemon WINDOWS command / `toki query windows`)

/// One rate-limit window instance as served by the daemon. Field names are the
/// daemon's versioned wire contract (schema 1) — see toki/src/windows.rs.
struct WindowRow: Codable, Sendable, Equatable, Hashable {
    let kind: String              // "session" | "weekly"
    let limitId: String           // "five_hour" | "seven_day" | ... | codex limit ids
    let account: String
    let windowEndMs: Int64
    let rawResetsAtMs: Int64
    let windowMinutes: Int
    let peakPct: Double
    /// Latest raw utilization — the live-display value (can decrease across
    /// server-side resets / credit refills, unlike the monotone peak).
    let lastPct: Double?
    let observedTsMs: Int64
    let firstSeenMs: Int64
    let finalized: Bool
    let maxedOut: Bool
    let limitReachedKind: Int     // 0 none, 1 hard stop, 2 continued on credits
    let timeTo100Ms: Int64        // -1 = never reached 100%
    let activeMs: Int64
    let lastSampleGapMs: Int64
    /// Coverage fraction ×1000 (present since daemon v2.3; optional for
    /// forward-compat with responses that omit it).
    let sampledActiveFraction: Int?
    let nSamples: Int
    let plan: String

    enum CodingKeys: String, CodingKey {
        case kind
        case limitId = "limit_id"
        case account
        case windowEndMs = "window_end_ms"
        case rawResetsAtMs = "raw_resets_at_ms"
        case windowMinutes = "window_minutes"
        case peakPct = "peak_pct"
        case lastPct = "last_pct"
        case observedTsMs = "observed_ts_ms"
        case firstSeenMs = "first_seen_ms"
        case finalized
        case maxedOut = "maxed_out"
        case limitReachedKind = "limit_reached_kind"
        case timeTo100Ms = "time_to_100_ms"
        case activeMs = "active_ms"
        case lastSampleGapMs = "last_sample_gap_ms"
        case sampledActiveFraction = "sampled_active_fraction"
        case nSamples = "n_samples"
        case plan
    }

    /// An open window is the provider's *current* state.
    func isOpen(nowMs: Int64) -> Bool {
        !finalized && rawResetsAtMs > nowMs
    }

    /// Live utilization: the latest raw value when the daemon provides it
    /// (older daemons omit last_pct — fall back to the peak).
    var livePct: Double { lastPct ?? peakPct }
}

struct WindowsProviderEntry: Codable, Sendable {
    let windows: [WindowRow]
    let authStatus: String        // "ok" | "missing" | "expired" | "unreadable"
    let lastSuccessMs: Int64?
    let lastPollMs: Int64?
    let plan: String?
    let pollingEnabled: Bool?
    let extraUsageEnabled: Bool?
    /// Account scope the daemon is currently collecting under; rows from a
    /// superseded login stay open until their own reset.
    let currentAccount: String?

    enum CodingKeys: String, CodingKey {
        case windows
        case authStatus = "auth_status"
        case lastSuccessMs = "last_success_ms"
        case lastPollMs = "last_poll_ms"
        case plan
        case pollingEnabled = "polling_enabled"
        case extraUsageEnabled = "extra_usage_enabled"
        case currentAccount = "current_account"
    }
}

struct WindowsResponse: Codable, Sendable {
    let ok: Bool
    let schema: Int?
    let nowMs: Int64?
    let refreshing: Bool?
    let providers: [String: WindowsProviderEntry]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, schema, refreshing, providers, error
        case nowMs = "now_ms"
    }
}

// MARK: - UDS client

enum WindowsFetchResult: Sendable {
    case success(WindowsResponse)
    /// The daemon answered but does not know the WINDOWS command (pre-v2.3
    /// binary) — callers fall back to direct provider polling and surface an
    /// update hint.
    case unsupported
    /// A current daemon with window tracking turned off, or a transient
    /// daemon-side error — fall back silently, no update hint.
    case unavailable
    /// No daemon / socket unreachable.
    case daemonDown
}

/// Native Unix-domain-socket client for the daemon's WINDOWS command.
/// Short-lived connection per request (local socket connects are ~µs); a 3s
/// deadline bounds the worst case even when the daemon is mid-refresh.
///
/// Requests are coordinated: the Claude and Codex monitors poll on their own
/// schedules but consume the same response, so concurrent fetches join a
/// single in-flight request and a short-lived cache serves back-to-back polls
/// without a second round-trip. `maxAgeMs: 0` (forced revalidation) always
/// bypasses both.
private actor WindowsFetchCoordinator {
    static let shared = WindowsFetchCoordinator()
    /// Serve identical requests from cache for this long.
    private static let cacheWindowMs: Int64 = 5_000

    private var cached: (atMs: Int64, result: WindowsFetchResult)?
    private var inflight: Task<WindowsFetchResult, Never>?
    /// Monotone request generation: a forced request may start while a normal
    /// one is still running; only the NEWEST completion may write the cache
    /// (and only the owner may clear `inflight`), so a slow older request can
    /// never roll the cache back over a fresher forced result.
    private var generation: UInt64 = 0

    func fetch(socketPath: String, maxAgeMs: Int64?) async -> WindowsFetchResult {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let forced = (maxAgeMs ?? .max) <= 0
        if !forced, let cached, nowMs - cached.atMs < Self.cacheWindowMs {
            return cached.result
        }
        if !forced, let inflight {
            return await inflight.value
        }
        generation += 1
        let myGeneration = generation
        let task = Task.detached(priority: .utility) {
            TokiWindowsClient.fetchBlocking(socketPath: socketPath, maxAgeMs: maxAgeMs)
        }
        inflight = task
        let result = await task.value
        if generation == myGeneration {
            inflight = nil
            cached = (Int64(Date().timeIntervalSince1970 * 1000), result)
        }
        return result
    }
}

enum TokiWindowsClient {

    /// Resolved once: `toki settings get daemon_sock`, falling back to the
    /// daemon's default path. Same pattern as CodexUsageClient's codex_root.
    private static let socketPath: String = {
        let fallback = NSString(string: "~/.config/toki/daemon.sock").expandingTildeInPath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: TokiPath.resolved)
        proc.arguments = ["settings", "get", "daemon_sock"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return fallback }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // `settings get` may echo "key = value" or the bare value; take the tail.
            let bare = value.components(separatedBy: "=").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? value
            guard !bare.isEmpty, bare.hasPrefix("/") else { return fallback }
            return bare
        } catch {
            return fallback
        }
    }()

    /// Fetch window state. `maxAgeMs: 0` asks the daemon to revalidate Claude's
    /// live state (bounded server-side at 2s; `refreshing=true` means it served
    /// stale and is refreshing in the background).
    static func fetch(maxAgeMs: Int64?) async -> WindowsFetchResult {
        await WindowsFetchCoordinator.shared.fetch(socketPath: socketPath, maxAgeMs: maxAgeMs)
    }

    fileprivate static func fetchBlocking(socketPath: String, maxAgeMs: Int64?) -> WindowsFetchResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .daemonDown }
        defer { close(fd) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return .daemonDown }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            pathBytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(maxLen)))
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .daemonDown }

        var request = "WINDOWS\n"
        if let maxAgeMs {
            request += "{\"max_age_ms\": \(maxAgeMs)}\n"
        } else {
            request += "{}\n"
        }
        // Write the full request: a partial write would reach the daemon as a
        // garbled command and come back as a misleading error reply.
        var ok = true
        request.withCString { cstr in
            var offset = 0
            let total = strlen(cstr)
            while offset < total {
                let n = write(fd, cstr + offset, total - offset)
                if n <= 0 { ok = false; return }
                offset += n
            }
        }
        guard ok else { return .daemonDown }

        // Read a single JSON line (bounded at 1 MiB).
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count < 1_048_576 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        guard !buffer.isEmpty else { return .daemonDown }
        if let newline = buffer.firstIndex(of: 0x0A) {
            buffer = buffer.prefix(upTo: newline)
        }

        guard let resp = try? JSONDecoder().decode(WindowsResponse.self, from: buffer) else {
            return .daemonDown
        }
        if resp.ok {
            // A schema we don't understand must be a typed miss, not a
            // silently-misdecoded success.
            if let schema = resp.schema, schema != 1 {
                return .unavailable
            }
            return .success(resp)
        }
        // Only "unknown command" proves an old binary. A current daemon with
        // tracking disabled (or any other daemon-side error) must not trigger
        // the "update toki" hint.
        if resp.error?.contains("unknown command") == true {
            return .unsupported
        }
        return .unavailable
    }
}
