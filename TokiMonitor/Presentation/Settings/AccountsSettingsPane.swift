import SwiftUI

struct AccountsSettingsPane: View {
    let oauthManager: ClaudeOAuthManager?
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            if let oauthManager {
                Section("Claude") {
                    ClaudeAccountSection(oauthManager: oauthManager, settings: settings)
                }
            } else {
                Section("Claude") {
                    Text("OAuth 매니저를 사용할 수 없습니다")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
