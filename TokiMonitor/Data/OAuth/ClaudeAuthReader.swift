import Foundation

/// A single Keychain read of Claude Code's OAuth credentials.
/// `hasOAuth` = an entry exists (user has logged in at least once);
/// `accessToken` = a currently-valid token, or nil when expired/unreadable.
struct ClaudeCredentials: Sendable {
    let hasOAuth: Bool
    let accessToken: String?

    static let none = ClaudeCredentials(hasOAuth: false, accessToken: nil)
}

/// Reads Claude Code's OAuth credentials from the macOS Keychain
/// using the `security` CLI tool — the standard approach used by
/// third-party tools integrating with Claude Code.
enum ClaudeAuthReader {
    private static let service = "Claude Code-credentials"

    /// Read credentials once, off the main thread. Spawns the `security`
    /// subprocess a single time and derives both availability and token
    /// validity from the same JSON payload. All parsing happens off-main so
    /// only the Sendable result crosses the concurrency boundary.
    static func read() async -> ClaudeCredentials {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readAndParse())
            }
        }
    }

    // MARK: - Private

    /// Runs `security find-generic-password` synchronously (call off-main only)
    /// and parses the result into `ClaudeCredentials`.
    private static func readAndParse() -> ClaudeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            // Guard against an indefinite hang (e.g. Keychain prompt).
            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeoutItem)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutItem.cancel()

            guard process.terminationStatus == 0, !data.isEmpty else {
                return .none
            }

            guard let jsonData = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                let oauth = json["claudeAiOauth"] as? [String: Any] else {
                return .none
            }

            guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
                // Entry exists but token is empty/unreadable → re-login required.
                return ClaudeCredentials(hasOAuth: true, accessToken: nil)
            }

            // Check expiration (expiresAt is epoch milliseconds)
            if let expiresAt = oauth["expiresAt"] as? Double {
                let expirationDate = Date(timeIntervalSince1970: expiresAt / 1000)
                if Date() >= expirationDate {
                    return ClaudeCredentials(hasOAuth: true, accessToken: nil)
                }
            }

            return ClaudeCredentials(hasOAuth: true, accessToken: token)
        } catch {
            return .none
        }
    }
}
