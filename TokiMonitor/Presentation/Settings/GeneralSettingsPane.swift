import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    var onClose: (() -> Void)?

    var body: some View {
        Form {
            Section("시작") {
                Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)
            }

            Section {
                HStack {
                    Text("Toki Monitor")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("v0.1.0")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
