import Foundation
import CryptoKit

/// Handles OAuth 2.0 PKCE flow with Anthropic's auth endpoints.
struct OAuthClient: Sendable {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let scopes = "user:profile user:inference"

    // MARK: - PKCE

    struct AuthorizationRequest {
        let authorizeURL: URL
        let codeVerifier: String
        let state: String
    }

    /// Build the authorization URL with PKCE challenge.
    static func buildAuthorizationRequest(redirectPort: UInt16) -> AuthorizationRequest {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(redirectPort)/callback"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        return AuthorizationRequest(
            authorizeURL: components.url!,
            codeVerifier: codeVerifier,
            state: state
        )
    }

    // MARK: - Token Exchange

    /// Exchange authorization code for tokens.
    static func exchangeCode(
        code: String,
        codeVerifier: String,
        state: String,
        redirectPort: UInt16
    ) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": "http://localhost:\(redirectPort)/callback",
            "state": state,
        ]

        let response: OAuthTokenResponse = try await postTokenRequest(body: body)
        return response.toTokens()
    }

    /// Refresh tokens using a refresh token.
    static func refreshToken(_ refreshToken: String) async throws -> OAuthTokens {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
            "scope": scopes,
        ]

        do {
            let response: OAuthTokenResponse = try await postTokenRequest(body: body)
            return response.toTokens()
        } catch let error as OAuthError {
            // Reclassify as refresh-specific error
            if case .tokenExchangeFailed(let code, let msg) = error {
                throw OAuthError.tokenRefreshFailed(code, msg)
            }
            throw error
        }
    }

    // MARK: - Private

    private static func postTokenRequest<T: Decodable>(body: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw OAuthError.tokenExchangeFailed(httpResponse.statusCode, msg)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }
}

// MARK: - Base64URL Encoding

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
