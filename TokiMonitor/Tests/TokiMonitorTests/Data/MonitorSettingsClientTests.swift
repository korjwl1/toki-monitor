import Testing
import Foundation
@testable import TokiMonitor

/// The monitor settings channel refuses in several distinct ways, and the
/// difference between them is the difference between "try again" and "you are
/// about to overwrite the work you did on your other Mac".
///
/// A 409 that arrives as a bare `HTTP 409` would be retried like any other
/// failure, and the retry would be the overwrite. So the reading of a response
/// is tested on its own, as a pure function, with no network anywhere near it.
@Suite("Reading the settings channel's refusals")
@MainActor
struct MonitorSettingsClientTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - The conflict

    @Test("409 is a lost write race, and says where the server is")
    func conflictCarriesTheServerVersion() {
        let error = MonitorSyncError.from(
            status: 409,
            body: body("""
                {"error":"version conflict: the stored entry moved since if_version was read",
                 "key":"dashboard:abc","current_version":7,"current_updated_at":1750000000}
                """),
            key: "dashboard:abc"
        )
        #expect(error == .conflict(key: "dashboard:abc", currentVersion: 7,
                                   currentUpdatedAt: 1_750_000_000))
    }

    @Test("a conflict is never reported as a plain status code")
    func conflictIsNotAStatus() {
        let error = MonitorSyncError.from(status: 409, body: body("{}"), key: "prefs:monitor")
        #expect(error != .httpError(409))
        guard case .conflict = error else {
            Issue.record("409 must decode as a conflict even when the body says nothing")
            return
        }
    }

    @Test("a version arriving as a string is still a version")
    func versionsMayBeStrings() {
        // Some backends render 64-bit counters as strings. Reading one as 0
        // would make the next write a compare-and-swap against "expect no
        // entry", which the server would refuse — or worse, would succeed on a
        // key that had just been deleted.
        let error = MonitorSyncError.from(
            status: 409,
            body: body("{\"current_version\":\"12\",\"current_updated_at\":\"99\"}"),
            key: "k"
        )
        #expect(error == .conflict(key: "k", currentVersion: 12, currentUpdatedAt: 99))
    }

    // MARK: - The rest of the refusals

    @Test("413 names the limit rather than the status")
    func oversizeIsRecognised() {
        let error = MonitorSyncError.from(
            status: 413, body: body("{\"error\":\"value is 400000 bytes, limit is 262144\"}"),
            key: "dashboard:big"
        )
        guard case let .valueTooLarge(key, _, limit) = error else {
            Issue.record("413 must map to valueTooLarge, got \(error)")
            return
        }
        #expect(key == "dashboard:big")
        #expect(limit == MonitorSettingsLimits.maxValueBytes)
    }

    @Test("507 keeps the server's own sentence about the quota")
    func quotaKeepsTheReason() {
        let reason = "monitor settings quota exceeded: total_bytes would reach 9000000, limit is 8388608"
        let error = MonitorSyncError.from(status: 507, body: body("{\"error\":\"\(reason)\"}"), key: "k")
        #expect(error == .quotaExceeded(reason: reason))
        #expect(error.errorDescription == reason)
    }

    @Test("429 backs off by the server's clock, not a guess")
    func rateLimitReadsRetryAfter() {
        let fromBody = MonitorSyncError.from(
            status: 429, body: body("{\"error\":\"too many\",\"retry_after\":42}"), key: "k"
        )
        #expect(fromBody == .rateLimited(retryAfter: 42))

        let fromHeader = MonitorSyncError.from(
            status: 429, body: body("{}"), key: "k", retryAfter: "17"
        )
        #expect(fromHeader == .rateLimited(retryAfter: 17))
    }

    @Test("422 names the key the server refused")
    func keyRefusalNamesTheKey() {
        let error = MonitorSyncError.from(
            status: 422, body: body("{\"error\":\"key may only contain letters, digits, and . _ - :\"}"),
            key: "dashboard:has/slash"
        )
        guard case let .keyRejected(key, reason) = error else {
            Issue.record("422 must map to keyRejected, got \(error)")
            return
        }
        #expect(key == "dashboard:has/slash")
        #expect(reason.contains("letters"))
    }

    @Test("404 and 401 keep their meanings")
    func notFoundAndExpiry() {
        #expect(MonitorSyncError.from(status: 404, body: body("{}"), key: "k") == .notFound(key: "k"))
        #expect(MonitorSyncError.from(status: 401, body: body("{}"), key: "k") == .tokenExpired)
    }

    @Test("an unclassified refusal still reaches the reader verbatim")
    func unclassifiedKeepsTheSentence() {
        let error = MonitorSyncError.from(
            status: 400, body: body("{\"error\":\"monitor settings are disabled on this server\"}"),
            key: "k"
        )
        #expect(error == .rejected(status: 400,
                                   reason: "monitor settings are disabled on this server"))
    }

    @Test("a body with nothing to say falls back to the status, not to silence")
    func emptyBodyFallsBack() {
        #expect(MonitorSyncError.from(status: 502, body: Data(), key: "k") == .httpError(502))
    }

    // MARK: - Keys

    @Test("the client applies the server's key grammar before uploading")
    func keyGrammarMatchesTheServer() {
        #expect(MonitorSettingsLimits.isValidKey("dashboard:a1b2c3d4"))
        #expect(MonitorSettingsLimits.isValidKey("prefs:monitor"))
        #expect(MonitorSettingsLimits.isValidKey("a.b_c-d:e"))

        #expect(!MonitorSettingsLimits.isValidKey(""))
        #expect(!MonitorSettingsLimits.isValidKey("has/slash"))
        #expect(!MonitorSettingsLimits.isValidKey("has space"))
        #expect(!MonitorSettingsLimits.isValidKey("대시보드"))
        #expect(!MonitorSettingsLimits.isValidKey(String(repeating: "a", count: 129)))
        #expect(MonitorSettingsLimits.isValidKey(String(repeating: "a", count: 128)))
    }

    @Test("a dashboard whose uid cannot be a key is not silently renamed")
    func illegalUIDDoesNotProduceAKey() {
        // Renaming it would change the identity two machines agree on, which is
        // how one dashboard ends up overwriting another.
        #expect(MonitorSyncKey.dashboard(uid: "a1b2c3d4") == "dashboard:a1b2c3d4")
        #expect(MonitorSyncKey.dashboard(uid: "with/slash") == nil)
        #expect(MonitorSyncKey.dashboard(uid: "대시보드") == nil)
        #expect(MonitorSyncKey.dashboardUID(fromKey: "dashboard:a1b2c3d4") == "a1b2c3d4")
        #expect(MonitorSyncKey.dashboardUID(fromKey: "prefs:monitor") == nil)
    }

    @Test("the mirrored limits are the server's limits")
    func limitsMatchTheServer() {
        // toki_sync/src/server/handlers/monitor.rs
        #expect(MonitorSettingsLimits.maxValueBytes == 256 * 1024)
        #expect(MonitorSettingsLimits.maxKeyLength == 128)
        #expect(MonitorSettingsLimits.maxEntries == 512)
        #expect(MonitorSettingsLimits.maxTotalBytes == 8 * 1024 * 1024)
    }
}
