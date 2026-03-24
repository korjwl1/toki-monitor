import Foundation

/// Reads Claude Code's OAuth credentials from the macOS Keychain
/// using the `security` CLI tool — the standard approach used by
/// third-party tools integrating with Claude Code.
enum ClaudeAuthReader {
    private static let service = "Claude Code-credentials"

    /// Read the current access token from Claude Code's Keychain entry.
    static func readAccessToken() -> String? {
        guard let json = readCredentialsJSON(),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }

        // Check expiration (expiresAt is epoch milliseconds)
        if let expiresAt = oauth["expiresAt"] as? Double {
            let expirationDate = Date(timeIntervalSince1970: expiresAt / 1000)
            if Date() >= expirationDate {
                return nil
            }
        }

        return token
    }

    /// Check if Claude Code credentials exist in Keychain.
    static var isAvailable: Bool {
        readCredentialsJSON()?["claudeAiOauth"] != nil
    }

    // MARK: - Private

    private static func readCredentialsJSON() -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", service, "-w"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0, !data.isEmpty else {
                    semaphore.signal()
                    return
                }

                if let jsonData = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .data(using: .utf8) {
                    result = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                }
            } catch {
                // Process failed to launch
            }
            semaphore.signal()
        }

        // Timeout after 5 seconds to avoid blocking indefinitely
        let timeout = semaphore.wait(timeout: .now() + 5)
        if timeout == .timedOut {
            return nil
        }
        return result
    }
}
