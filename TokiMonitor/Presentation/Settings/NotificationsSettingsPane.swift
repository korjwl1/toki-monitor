import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Claude 사용량 알림") {
                Toggle("75% 도달 시 알림", isOn: $settings.claudeAlert75)
                Toggle("90% 도달 시 알림", isOn: $settings.claudeAlert90)
            }
        }
        .formStyle(.grouped)
    }
}
