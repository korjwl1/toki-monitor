import SwiftUI

/// Claude account login/logout + alert settings in the Settings panel.
struct ClaudeAccountSection: View {
    let oauthManager: ClaudeOAuthManager
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Claude 계정")

            switch oauthManager.authState {
            case .loggedOut:
                Button(action: { oauthManager.login() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.key")
                        Text("Claude 로그인")
                    }
                }
                .controlSize(.regular)

            case .loggingIn:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("인증 대기 중...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

            case .loggedIn:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("로그인됨")
                        .font(.system(size: 12))
                    Spacer()
                    Button("로그아웃") { oauthManager.logout() }
                        .controlSize(.small)
                }

                Divider()

                Toggle("75% 사용량 알림", isOn: $settings.claudeAlert75)
                    .font(.system(size: 12))
                Toggle("90% 사용량 알림", isOn: $settings.claudeAlert90)
                    .font(.system(size: 12))

            case .error(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("인증 실패")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                    Button("다시 시도") { oauthManager.login() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }
}
