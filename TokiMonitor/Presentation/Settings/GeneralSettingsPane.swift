import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var settings: AppSettings
    var onClose: (() -> Void)?

    var body: some View {
        Form {
            Section(L.general.language) {
                Picker(L.general.language, selection: $settings.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .background(scrollTopTracker)
            }

            Section(L.general.startup) {
                Toggle(L.general.launchAtLogin, isOn: $settings.launchAtLogin)
            }

            Section {
                HStack {
                    Text("Toki Monitor")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
