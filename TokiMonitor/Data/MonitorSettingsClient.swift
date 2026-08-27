import Foundation

// MARK: - The monitor settings channel
//
// A user-scoped key/value store on the sync server, for the monitor's OWN
// configuration: dashboard definitions and display preferences.
//
// It is deliberately not part of `toki_sync_protocol`. That protocol carries
// toki's collected usage data and nothing else, and it stays that way. This is
// a separate, opt-in channel over plain HTTP with the same bearer auth as every
// other `/me` route, so a toki user who never runs the monitor never touches it
// and a monitor user who does not want their dashboards on the server can leave
// it off.
//
// Payloads are opaque to the server: it stores the bytes it is given and hands
// the same bytes back. Nothing here may send a query RESULT, a usage figure or
// a cost — only configuration (계약 C3).

/// Limits the server enforces. Mirrored here so an oversize write is refused
/// before it is uploaded rather than after; the server remains the authority
/// and its refusal is still handled.
enum MonitorSettingsLimits {
    static let maxValueBytes = 256 * 1024
    static let maxKeyLength = 128
    static let maxEntries = 512
    static let maxTotalBytes = 8 * 1024 * 1024

    /// The server's key grammar: ASCII alphanumerics plus `. _ - :`. A key that
    /// breaks it is rejected there, so it is caught here first — silently
    /// rewriting one would make two different dashboards share a key.
    static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= maxKeyLength else { return false }
        return key.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" || c == ":")
        }
    }
}

// MARK: - Wire shapes

/// One stored entry, payload included.
struct MonitorSettingEntry: Equatable, Sendable {
    var key: String
    var value: String
    var version: Int64
    var updatedAt: Int64
}

/// One stored entry with the payload left behind, for deciding what is worth
/// fetching.
struct MonitorSettingMeta: Equatable, Sendable {
    var key: String
    var version: Int64
    var updatedAt: Int64
    var sizeBytes: Int
}

struct MonitorSettingsQuota: Equatable, Sendable {
    var maxEntries: Int
    var maxValueBytes: Int
    var maxTotalBytes: Int
    var usedEntries: Int
    var usedBytes: Int

    static let unknown = MonitorSettingsQuota(
        maxEntries: MonitorSettingsLimits.maxEntries,
        maxValueBytes: MonitorSettingsLimits.maxValueBytes,
        maxTotalBytes: MonitorSettingsLimits.maxTotalBytes,
        usedEntries: 0,
        usedBytes: 0
    )
}

/// What the server holds, without the payloads.
struct MonitorSettingsIndex: Equatable, Sendable {
    var entries: [MonitorSettingMeta]
    var quota: MonitorSettingsQuota

    func meta(for key: String) -> MonitorSettingMeta? {
        entries.first { $0.key == key }
    }
}

/// What a write did.
struct MonitorSettingWrite: Equatable, Sendable {
    var key: String
    var version: Int64
    var updatedAt: Int64
    /// The version this write replaced, or nil when it created the entry.
    var previousVersion: Int64?
    var created: Bool
}

// MARK: - Errors

/// Every way this channel can refuse, with the distinctions that change what
/// the app must do about it.
///
/// `conflict` is the one that matters most: it means another machine wrote
/// since the version this write was based on, and the user has to choose. It is
/// never handled by picking a side.
enum MonitorSyncError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL
    case invalidResponse
    case notFound(key: String)
    /// Lost a write race (HTTP 409). Carries where the server actually is.
    case conflict(key: String, currentVersion: Int64, currentUpdatedAt: Int64)
    /// HTTP 413.
    case valueTooLarge(key: String, bytes: Int, limit: Int)
    /// HTTP 507.
    case quotaExceeded(reason: String)
    /// HTTP 429, with the server's own backoff.
    case rateLimited(retryAfter: Int)
    /// HTTP 422 — the key broke the server's grammar, or ours did first.
    case keyRejected(key: String, reason: String)
    case tokenExpired
    /// A refusal that named itself. The server's sentence is kept intact, the
    /// way `ServerQueryError.rejected` keeps a query refusal's.
    case rejected(status: Int, reason: String)
    case httpError(Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L.sync.notConfigured
        case .invalidURL:
            return L.tr("잘못된 URL", "Invalid URL")
        case .invalidResponse:
            return L.tr("잘못된 응답", "Invalid response")
        case .notFound(let key):
            return L.tr("서버에 '\(key)' 항목이 없습니다", "The server has no entry '\(key)'")
        case let .conflict(key, version, _):
            return L.tr(
                "'\(key)'은(는) 다른 기기에서 먼저 바뀌었습니다 (서버 버전 \(version)).",
                "'\(key)' changed on another device first (server version \(version))."
            )
        case let .valueTooLarge(key, bytes, limit):
            return L.tr(
                "'\(key)'이(가) \(bytes)바이트로 한도 \(limit)바이트를 넘습니다.",
                "'\(key)' is \(bytes) bytes, over the \(limit) byte limit."
            )
        case .quotaExceeded(let reason):
            return reason
        case .rateLimited(let retryAfter):
            return L.tr(
                "쓰기가 너무 잦습니다. \(retryAfter)초 후 다시 시도합니다.",
                "Too many writes. Retrying in \(retryAfter)s."
            )
        case let .keyRejected(key, reason):
            return L.tr("서버가 '\(key)' 키를 거부했습니다: \(reason)",
                        "The server rejected the key '\(key)': \(reason)")
        case .tokenExpired:
            return L.sync.tokenExpired
        case .rejected(_, let reason):
            return reason
        case .httpError(let code):
            return "HTTP \(code)"
        case .networkError(let message):
            return message
        }
    }
}

extension MonitorSyncError {

    /// Map a non-2xx response onto an error that keeps what the server said.
    ///
    /// Split out as a pure function on purpose: what must not regress is the
    /// READING of the response — a 409 that arrives as a bare `httpError(409)`
    /// would let a lost write race look like an ordinary failure and get
    /// retried, which is exactly how the other machine's edit gets overwritten.
    static func from(status: Int, body: Data, key: String, retryAfter: String? = nil) -> MonitorSyncError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = ServerQueryError.refusalReason(in: body)

        switch status {
        case 404:
            return .notFound(key: key)
        case 409:
            return .conflict(
                key: (object?["key"] as? String) ?? key,
                currentVersion: int64(object?["current_version"]) ?? 0,
                currentUpdatedAt: int64(object?["current_updated_at"]) ?? 0
            )
        case 413:
            return .valueTooLarge(
                key: key,
                bytes: Int(int64(object?["size"]) ?? 0),
                limit: MonitorSettingsLimits.maxValueBytes
            )
        case 507:
            return .quotaExceeded(
                reason: reason ?? L.tr("서버 저장 한도를 넘었습니다", "Server storage quota exceeded")
            )
        case 429:
            let fromBody = int64(object?["retry_after"])
            let fromHeader = retryAfter.flatMap { Int64($0) }
            return .rateLimited(retryAfter: Int(fromBody ?? fromHeader ?? 60))
        case 422:
            return .keyRejected(
                key: key,
                reason: reason ?? L.tr("키 형식이 올바르지 않습니다", "the key is not well formed")
            )
        case 401:
            return .tokenExpired
        default:
            guard let reason else { return .httpError(status) }
            return .rejected(status: status, reason: reason)
        }
    }

    /// The server sends 64-bit counters; JSON hands them back as `NSNumber` or,
    /// on some backends, as a string. Read both rather than silently getting a
    /// version of 0 and turning a conflict into an overwrite.
    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

// MARK: - Transport

/// The five calls this channel needs.
///
/// A protocol so the sync engine can be exercised against a fake server. The
/// engine is where the decisions live that must never lose a dashboard, and
/// those decisions have to be provable without a network.
protocol MonitorSettingsTransport: Sendable {
    /// What exists on the server, without payloads.
    func index() async throws -> MonitorSettingsIndex
    /// Everything, payloads included.
    func list() async throws -> [MonitorSettingEntry]
    /// One entry.
    func get(key: String) async throws -> MonitorSettingEntry
    /// Store or replace.
    ///
    /// `ifVersion` is a compare-and-swap: pass the version this edit was based
    /// on and the write lands only if the server is still there; pass `0` to
    /// mean "expect no entry". Passing nil overwrites whatever is there and is
    /// only correct once the user has said to.
    @discardableResult
    func put(key: String, value: String, ifVersion: Int64?) async throws -> MonitorSettingWrite
    /// Remove.
    func delete(key: String) async throws
}

// MARK: - Client

/// Talks to `/me/monitor/*` on the sync server.
///
/// Auth, base URL and 401-refresh-and-retry come from `SyncClient`, the same
/// way `ServerQueryClient` gets them. There is one place credentials live and
/// this is not a second one.
final class MonitorSettingsClient: @unchecked Sendable, MonitorSettingsTransport {
    @MainActor private let syncClient: SyncClient
    private let session: URLSession

    @MainActor
    init(syncClient: SyncClient = .shared, session: URLSession = .shared) {
        self.syncClient = syncClient
        self.session = session
    }

    // MARK: Reads

    func index() async throws -> MonitorSettingsIndex {
        let data = try await send(path: "/me/monitor/index", method: "GET", key: "index", body: nil)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MonitorSyncError.invalidResponse
        }
        let rows = (object["entries"] as? [[String: Any]]) ?? []
        let entries = rows.compactMap { row -> MonitorSettingMeta? in
            guard let key = row["key"] as? String else { return nil }
            return MonitorSettingMeta(
                key: key,
                version: Self.int64(row["version"]) ?? 0,
                updatedAt: Self.int64(row["updated_at"]) ?? 0,
                sizeBytes: Int(Self.int64(row["size_bytes"]) ?? 0)
            )
        }
        let q = object["quota"] as? [String: Any]
        let quota = MonitorSettingsQuota(
            maxEntries: Int(Self.int64(q?["max_entries"]) ?? Int64(MonitorSettingsLimits.maxEntries)),
            maxValueBytes: Int(Self.int64(q?["max_value_bytes"]) ?? Int64(MonitorSettingsLimits.maxValueBytes)),
            maxTotalBytes: Int(Self.int64(q?["max_total_bytes"]) ?? Int64(MonitorSettingsLimits.maxTotalBytes)),
            usedEntries: Int(Self.int64(q?["used_entries"]) ?? 0),
            usedBytes: Int(Self.int64(q?["used_bytes"]) ?? 0)
        )
        return MonitorSettingsIndex(entries: entries, quota: quota)
    }

    func list() async throws -> [MonitorSettingEntry] {
        let data = try await send(path: "/me/monitor/settings", method: "GET", key: "settings", body: nil)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["entries"] as? [[String: Any]] else {
            throw MonitorSyncError.invalidResponse
        }
        return rows.compactMap(Self.entry(from:))
    }

    func get(key: String) async throws -> MonitorSettingEntry {
        try Self.requireValidKey(key)
        let data = try await send(
            path: "/me/monitor/settings/\(Self.escape(key))", method: "GET", key: key, body: nil
        )
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = Self.entry(from: object) else {
            throw MonitorSyncError.invalidResponse
        }
        return entry
    }

    // MARK: Writes

    @discardableResult
    func put(key: String, value: String, ifVersion: Int64?) async throws -> MonitorSettingWrite {
        try Self.requireValidKey(key)
        let bytes = value.utf8.count
        guard bytes <= MonitorSettingsLimits.maxValueBytes else {
            // Refused here rather than uploaded and refused there. The server
            // caps the request body below the escaped worst case, so a maximal
            // value with awkward characters would come back as a bare 413 with
            // no sentence in it.
            throw MonitorSyncError.valueTooLarge(
                key: key, bytes: bytes, limit: MonitorSettingsLimits.maxValueBytes
            )
        }

        var payload: [String: Any] = ["value": value]
        if let ifVersion { payload["if_version"] = ifVersion }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        guard let body else { throw MonitorSyncError.invalidResponse }

        let data = try await send(
            path: "/me/monitor/settings/\(Self.escape(key))", method: "PUT", key: key, body: body
        )
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MonitorSyncError.invalidResponse
        }
        return MonitorSettingWrite(
            key: object["key"] as? String ?? key,
            version: Self.int64(object["version"]) ?? 0,
            updatedAt: Self.int64(object["updated_at"]) ?? 0,
            previousVersion: Self.int64(object["previous_version"]),
            created: (object["created"] as? Bool) ?? (object["previous_version"] == nil)
        )
    }

    func delete(key: String) async throws {
        try Self.requireValidKey(key)
        _ = try await send(
            path: "/me/monitor/settings/\(Self.escape(key))", method: "DELETE", key: key, body: nil
        )
    }

    // MARK: - HTTP

    /// One request, with 401 → refresh → retry once. Mirrors
    /// `ServerQueryClient.tokiQuery`; the difference is that a write is NOT
    /// retried on a transient failure, because a PUT whose response was lost
    /// may already have landed and a blind repeat would burn the version this
    /// client is holding.
    private func send(path: String, method: String, key: String, body: Data?) async throws -> Data {
        let creds = try await requireCredentials()
        return try await send(path: path, method: method, key: key, body: body,
                              creds: creds, retryOn401: true)
    }

    private func send(
        path: String, method: String, key: String, body: Data?,
        creds: SyncCredentials, retryOn401: Bool
    ) async throws -> Data {
        guard let url = URL(string: "\(creds.httpURL)\(path)") else {
            throw MonitorSyncError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MonitorSyncError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MonitorSyncError.invalidResponse
        }

        if http.statusCode == 401, retryOn401 {
            do {
                let refreshed = try await syncClient.refreshAccessToken(creds)
                return try await send(path: path, method: method, key: key, body: body,
                                      creds: refreshed, retryOn401: false)
            } catch is SyncClientError {
                await SyncManager.shared.markTokenExpired()
                throw MonitorSyncError.tokenExpired
            } catch {
                throw MonitorSyncError.httpError(http.statusCode)
            }
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MonitorSyncError.from(
                status: http.statusCode, body: data, key: key,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return data
    }

    // MARK: - Helpers

    @MainActor
    private func requireCredentials() throws -> SyncCredentials {
        guard let creds = syncClient.load() else { throw MonitorSyncError.notConfigured }
        return creds
    }

    private static func requireValidKey(_ key: String) throws {
        guard MonitorSettingsLimits.isValidKey(key) else {
            throw MonitorSyncError.keyRejected(
                key: key,
                reason: L.tr("키는 영문·숫자와 . _ - : 만 쓸 수 있고 \(MonitorSettingsLimits.maxKeyLength)자 이하여야 합니다",
                             "keys may contain only letters, digits and . _ - : and must be at most \(MonitorSettingsLimits.maxKeyLength) characters")
            )
        }
    }

    /// The grammar admits `:`, which is legal in a path segment but is escaped
    /// by some proxies; `.` `_` `-` and alphanumerics need nothing.
    private static func escape(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-:")))
            ?? key
    }

    private static func entry(from row: [String: Any]) -> MonitorSettingEntry? {
        guard let key = row["key"] as? String, let value = row["value"] as? String else { return nil }
        return MonitorSettingEntry(
            key: key,
            value: value,
            version: int64(row["version"]) ?? 0,
            updatedAt: int64(row["updated_at"]) ?? 0
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}
