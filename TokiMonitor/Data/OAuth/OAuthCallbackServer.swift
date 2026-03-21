import Foundation
import Network

/// Ephemeral local HTTP server that receives the OAuth redirect callback.
/// Starts on a random port, handles one request, then shuts down.
final class OAuthCallbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private(set) var port: UInt16 = 0

    /// Start the server and wait for the OAuth callback.
    func waitForCallback() async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    if case .ready = state, let port = listener.port {
                        self?.port = port.rawValue
                    }
                    if case .failed(let error) = state {
                        self?.finish(with: .failure(OAuthError.callbackFailed(error.localizedDescription)))
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }

                listener.start(queue: .global(qos: .userInitiated))

                // Timeout after 120 seconds
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in
                    self?.finish(with: .failure(OAuthError.callbackFailed("Timeout waiting for callback")))
                }
            } catch {
                continuation.resume(throwing: OAuthError.callbackFailed(error.localizedDescription))
            }
        }
    }

    /// The port the server is listening on. Wait briefly for it to be assigned.
    func getPort() async -> UInt16 {
        for _ in 0..<50 {
            if port != 0 { return port }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.finish(with: .failure(OAuthError.callbackFailed(error.localizedDescription)))
                return
            }

            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.finish(with: .failure(OAuthError.callbackFailed("Empty request")))
                return
            }

            // Parse GET /callback?code=xxx&state=yyy
            if let result = Self.parseCallback(request) {
                let response = Self.buildSuccessResponse()
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self.finish(with: .success(result))
            } else {
                let response = Self.buildErrorResponse()
                connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                self.finish(with: .failure(OAuthError.callbackFailed("Missing code or state in callback")))
            }
        }
    }

    private func finish(with result: Result<(code: String, state: String), Error>) {
        stop()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static func parseCallback(_ request: String) -> (code: String, state: String)? {
        // Extract path from "GET /callback?code=xxx&state=yyy HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first,
              let urlComponents = URLComponents(string: String(pathPart)),
              let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = urlComponents.queryItems?.first(where: { $0.name == "state" })?.value
        else { return nil }
        return (code: code, state: state)
    }

    private static func buildSuccessResponse() -> String {
        let body = """
        <html><body style="font-family:system-ui;text-align:center;padding:60px;color:#333">
        <h2 style="color:#22c55e">✓ 인증 완료</h2>
        <p>이 탭을 닫아도 됩니다.</p>
        <script>try{window.close()}catch(e){}</script>
        </body></html>
        """
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private static func buildErrorResponse() -> String {
        let body = "<html><body><h2>인증 실패</h2></body></html>"
        return "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}
