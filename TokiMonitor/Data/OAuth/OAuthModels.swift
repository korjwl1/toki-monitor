import Foundation

// MARK: - OAuth Errors (Data layer — thrown by ClaudeUsageClient)

enum OAuthError: Error, LocalizedError {
    case usageFetchFailed(Int)

    var errorDescription: String? {
        switch self {
        case .usageFetchFailed(let code): "Usage fetch failed (\(code))"
        }
    }
}
