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
                    Text(L.account.oauthUnavailable)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
