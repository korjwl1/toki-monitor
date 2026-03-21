import AppKit

/// Manages OAuth login/logout and token lifecycle for Claude usage API.
@MainActor
@Observable
final class ClaudeOAuthManager {
    enum AuthState: Equatable {
        case loggedOut
        case loggingIn
        case loggedIn
        case error(String)
    }

    private(set) var authState: AuthState = .loggedOut
    private let tokenStore = KeychainTokenStore()
    private var tokens: OAuthTokens?
    private var refreshTask: Task<OAuthTokens, Error>?
    private var proactiveRefreshTimer: Timer?

    init() {
        // Try to restore from Keychain
        if let stored = tokenStore.load() {
            if stored.isExpired {
                // Try refresh on next getValidToken() call
                tokens = stored
                authState = .loggedIn
            } else {
                tokens = stored
                authState = .loggedIn
                scheduleProactiveRefresh()
            }
        }
    }

    // MARK: - Login

    func login() {
        guard authState != .loggingIn else { return }
        authState = .loggingIn

        Task {
            do {
                let server = OAuthCallbackServer()

                // Start server and wait for port assignment
                let callbackTask = Task { try await server.waitForCallback() }
                let port = await server.getPort()
                guard port != 0 else {
                    authState = .error("서버 시작 실패")
                    return
                }

                // Build and open authorize URL
                let authRequest = OAuthClient.buildAuthorizationRequest(redirectPort: port)
                NSWorkspace.shared.open(authRequest.authorizeURL)

                // Wait for callback
                let callback = try await callbackTask.value

                // Verify state
                guard callback.state == authRequest.state else {
                    authState = .error("인증 상태 불일치")
                    return
                }

                // Exchange code for tokens
                let newTokens = try await OAuthClient.exchangeCode(
                    code: callback.code,
                    codeVerifier: authRequest.codeVerifier,
                    state: authRequest.state,
                    redirectPort: port
                )

                try tokenStore.save(newTokens)
                tokens = newTokens
                authState = .loggedIn
                scheduleProactiveRefresh()

                // Bring app to foreground after browser auth
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                authState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Logout

    func logout() {
        proactiveRefreshTimer?.invalidate()
        proactiveRefreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        tokenStore.delete()
        tokens = nil
        authState = .loggedOut
    }

    // MARK: - Token Access

    /// Get a valid access token, refreshing if needed.
    /// Uses deduplication — concurrent callers share the same refresh task.
    func getValidAccessToken() async throws -> String {
        guard var currentTokens = tokens else {
            throw OAuthError.noTokens
        }

        if !currentTokens.needsProactiveRefresh {
            return currentTokens.accessToken
        }

        // Refresh needed — deduplicate
        let task = refreshTask ?? Task {
            defer { refreshTask = nil }
            return try await refreshTokens(using: currentTokens.refreshToken)
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            return refreshed.accessToken
        } catch let error as OAuthError where !error.isTransient {
            // Permanent failure — log out
            logout()
            throw OAuthError.permanentAuthFailure
        }
    }

    /// Force refresh token to get a new access token (resets rate limit window).
    func forceRefreshToken() async throws -> String {
        guard let currentTokens = tokens else { throw OAuthError.noTokens }
        let refreshed = try await refreshTokens(using: currentTokens.refreshToken)
        return refreshed.accessToken
    }

    // MARK: - Private

    private func refreshTokens(using refreshToken: String, retryCount: Int = 0) async throws -> OAuthTokens {
        do {
            let newTokens = try await OAuthClient.refreshToken(refreshToken)
            try tokenStore.save(newTokens)
            tokens = newTokens
            scheduleProactiveRefresh()
            return newTokens
        } catch let error as OAuthError where error.isTransient && retryCount < 3 {
            // Exponential backoff for transient errors
            let delay = UInt64(pow(2.0, Double(retryCount))) * 1_000_000_000
            try await Task.sleep(nanoseconds: delay)
            return try await refreshTokens(using: refreshToken, retryCount: retryCount + 1)
        }
    }

    private func scheduleProactiveRefresh() {
        proactiveRefreshTimer?.invalidate()
        guard let tokens else { return }

        let timeUntilRefresh = tokens.expiresAt.timeIntervalSinceNow - 300
        guard timeUntilRefresh > 0 else {
            // Already needs refresh
            Task { _ = try? await getValidAccessToken() }
            return
        }

        proactiveRefreshTimer = Timer.scheduledTimer(withTimeInterval: timeUntilRefresh, repeats: false) { [weak self] _ in
            Task { @MainActor in
                _ = try? await self?.getValidAccessToken()
            }
        }
    }
}
