import SwiftUI

/// Claude account login/logout + alert settings in the Settings panel.
struct ClaudeAccountSection: View {
    let oauthManager: ClaudeOAuthManager
    @Bindable var settings: AppSettings

    var body: some View {
        switch oauthManager.authState {
        case .loggedOut:
            Button(action: { oauthManager.login() }) {
                Label("Claude 로그인", systemImage: "person.badge.key")
            }

        case .loggingIn:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("인증 대기 중...")
                    .foregroundStyle(.secondary)
            }

        case .loggedIn:
            HStack {
                Label("로그인됨", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("로그아웃") { oauthManager.logout() }
                    .controlSize(.small)
            }

            Toggle("75% 사용량 알림", isOn: $settings.claudeAlert75)
            Toggle("90% 사용량 알림", isOn: $settings.claudeAlert90)

        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Label("인증 실패", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                Button("다시 시도") { oauthManager.login() }
                    .controlSize(.small)
            }
        }
    }
}
