import SwiftUI

/// Claude account login/logout + alert settings in the Settings panel.
struct ClaudeAccountSection: View {
    let oauthManager: ClaudeOAuthManager
    @Bindable var settings: AppSettings

    var body: some View {
        switch oauthManager.authState {
        case .loggedOut:
            Button(action: { oauthManager.login() }) {
                Label(L.account.login, systemImage: "person.badge.key")
            }

        case .loggingIn:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L.account.loggingIn)
                    .foregroundStyle(.secondary)
            }

        case .loggedIn:
            HStack {
                Label(L.account.loggedIn, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button(L.account.logout) { oauthManager.logout() }
                    .controlSize(.small)
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Label(L.account.authFailed, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                Button(L.account.retry) { oauthManager.login() }
                    .controlSize(.small)
            }
        }
    }
}
