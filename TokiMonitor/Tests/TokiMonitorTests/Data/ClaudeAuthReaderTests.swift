import Foundation
import Testing
@testable import TokiMonitor

@Suite("ClaudeAuthReader.classify")
struct ClaudeAuthReaderTests {

    private func oauthData(token: String?, expiresAtMs: Double?) -> Data {
        var oauth: [String: Any] = [:]
        if let token { oauth["accessToken"] = token }
        if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
        let json: [String: Any] = ["claudeAiOauth": oauth]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private var futureMs: Double { (Date().timeIntervalSince1970 + 3600) * 1000 }
    private var pastMs: Double { (Date().timeIntervalSince1970 - 3600) * 1000 }

    @Test("Valid unexpired token → credentials")
    func validToken() {
        let data = oauthData(token: "tok-123", expiresAtMs: futureMs)
        #expect(ClaudeAuthReader.classify(signaled: false, status: 0, data: data) == .credentials("tok-123"))
    }

    @Test("Token with no expiresAt is treated as valid")
    func noExpiry() {
        let data = oauthData(token: "tok-123", expiresAtMs: nil)
        #expect(ClaudeAuthReader.classify(signaled: false, status: 0, data: data) == .credentials("tok-123"))
    }

    @Test("Expired token → expired (re-login)")
    func expiredToken() {
        let data = oauthData(token: "tok-123", expiresAtMs: pastMs)
        #expect(ClaudeAuthReader.classify(signaled: false, status: 0, data: data) == .expired)
    }

    @Test("Empty token → expired")
    func emptyToken() {
        let data = oauthData(token: "", expiresAtMs: futureMs)
        #expect(ClaudeAuthReader.classify(signaled: false, status: 0, data: data) == .expired)
    }

    @Test("Exit 44 (errSecItemNotFound) → missing, never logged in")
    func itemNotFound() {
        #expect(ClaudeAuthReader.classify(signaled: false, status: 44, data: Data()) == .missing)
    }

    @Test("Signal termination (timeout) → unreadable, NOT missing")
    func signaledIsTransient() {
        // A timeout-kill must not look like logout — otherwise valid usage is wiped.
        if case .unreadable = ClaudeAuthReader.classify(signaled: true, status: 15, data: Data()) {
        } else {
            Issue.record("signaled read should classify as unreadable")
        }
    }

    @Test("Non-zero, non-44 exit → unreadable (transient)")
    func otherNonZeroIsTransient() {
        if case .unreadable = ClaudeAuthReader.classify(signaled: false, status: 1, data: Data()) {
        } else {
            Issue.record("ambiguous non-zero exit should classify as unreadable")
        }
    }

    @Test("Exit 0 but empty output → unreadable")
    func emptyOutputIsTransient() {
        if case .unreadable = ClaudeAuthReader.classify(signaled: false, status: 0, data: Data()) {
        } else {
            Issue.record("empty successful output should classify as unreadable")
        }
    }

    @Test("Malformed JSON → unreadable, NOT missing")
    func malformedJSON() {
        let data = "not json at all".data(using: .utf8)!
        if case .unreadable = ClaudeAuthReader.classify(signaled: false, status: 0, data: data) {
        } else {
            Issue.record("malformed payload should classify as unreadable")
        }
    }

    @Test("Valid JSON without claudeAiOauth key → unreadable")
    func missingOAuthKey() {
        let data = try! JSONSerialization.data(withJSONObject: ["something": "else"])
        if case .unreadable = ClaudeAuthReader.classify(signaled: false, status: 0, data: data) {
        } else {
            Issue.record("payload without claudeAiOauth should classify as unreadable")
        }
    }
}
