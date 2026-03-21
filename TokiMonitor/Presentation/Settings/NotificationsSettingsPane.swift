import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section(L.notification.claudeUsageAlerts) {
                Toggle(L.notification.alert75, isOn: $settings.claudeAlert75)
                Toggle(L.notification.alert90, isOn: $settings.claudeAlert90)
            }
        }
        .formStyle(.grouped)
    }
}
