import Foundation

/// Outcome of a single Keychain read of Claude Code's OAuth credentials.
/// The distinction between `missing` and `unreadable` is load-bearing: `missing`
/// means the user is logged out (wipe usage, show login), while `unreadable` is a
/// transient failure (timeout, launch failure, malformed payload) where we must
/// KEEP the prior usage/state and retry, never flash a false re-login prompt.
enum ClaudeAuthResult: Sendable, Equatable {
    /// Keychain entry present with a currently-valid access token.
    case credentials(String)
    /// Entry present but the token is empty/expired → re-login required.
    case expired
    /// No Keychain entry at all → never logged in.
    case missing
    /// The read itself failed transiently; prior state should be preserved.
    case unreadable(String)
}

/// Reads Claude Code's OAuth credentials from the macOS Keychain
/// using the `security` CLI tool — the standard approach used by
/// third-party tools integrating with Claude Code.
enum ClaudeAuthReader {
    private static let service = "Claude Code-credentials"

    /// Read credentials once, off the main thread. Spawns the `security`
    /// subprocess a single time and derives availability, token validity, and
    /// transient-failure status from the same invocation. All parsing happens
    /// off-main so only the Sendable result crosses the concurrency boundary.
    static func read() async -> ClaudeAuthResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readAndParse())
            }
        }
    }

    // MARK: - Private

    /// Runs `security find-generic-password` synchronously (call off-main only)
    /// and classifies the result.
    private static func readAndParse() -> ClaudeAuthResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            // Guard against an indefinite hang (e.g. Keychain prompt). If the
            // timeout fires we SIGTERM the process, which surfaces below as a
            // signal termination → classified as `unreadable`, not `missing`.
            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeoutItem)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutItem.cancel()

            return classify(
                signaled: process.terminationReason == .uncaughtSignal,
                status: process.terminationStatus,
                data: data
            )
        } catch {
            return .unreadable("failed to launch security: \(error.localizedDescription)")
        }
    }

    /// Pure classification of a `security` invocation's outcome. Split out so the
    /// missing-vs-unreadable decision — which governs whether we wipe usage and
    /// prompt re-login — is unit-testable without spawning a subprocess.
    static func classify(signaled: Bool, status: Int32, data: Data) -> ClaudeAuthResult {
        // Killed by a signal (our timeout, or otherwise) → transient, not logout.
        if signaled {
            return .unreadable("keychain read timed out or was signaled")
        }
        // errSecItemNotFound → `security` exits 44: the entry truly doesn't exist.
        if status == 44 {
            return .missing
        }
        // Any other non-zero exit (or empty output) is ambiguous; treat as
        // transient so a flaky read never wipes valid usage.
        guard status == 0, !data.isEmpty else {
            return .unreadable("security exited \(status)")
        }

        guard let jsonData = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return .unreadable("malformed keychain payload")
        }

        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            // Entry exists but token is empty → re-login required.
            return .expired
        }

        // Check expiration (expiresAt is epoch milliseconds)
        if let expiresAt = oauth["expiresAt"] as? Double {
            let expirationDate = Date(timeIntervalSince1970: expiresAt / 1000)
            if Date() >= expirationDate {
                return .expired
            }
        }

        return .credentials(token)
    }
}
