import SwiftUI

struct ProvidersSettingsPane: View {
    @Bindable var settings: AppSettings
    let oauthManager: ClaudeOAuthManager?

    var body: some View {
        Form {
            ForEach(ProviderRegistry.configurableProviders) { provider in
                Section {
                    providerRow(provider)

                    // Claude 계정 연동 (활성화된 경우만)
                    if provider.id == "anthropic",
                       settings.effectiveSettings(for: provider.id).enabled,
                       let oauthManager {
                        ClaudeAccountSection(oauthManager: oauthManager, settings: settings)
                    }

                    // 개별 모드일 때 스타일 오버라이드
                    if settings.providerDisplayMode == .perProvider,
                       settings.effectiveSettings(for: provider.id).enabled {
                        individualProviderOptions(provider)
                    }
                } header: {
                    Label(provider.name, systemImage: provider.icon)
                        .foregroundStyle(provider.color)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func providerRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)

        return Toggle("활성화", isOn: Binding(
            get: { ps.enabled },
            set: { newVal in
                settings.setProviderEnabled(
                    provider.id,
                    enabled: newVal,
                    tokiProviderId: provider.tokiProviderId
                )
            }
        ))
    }

    private func individualProviderOptions(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)

        return Group {
            HStack {
                Text("색상")
                Spacer()
                colorPickerMenu(
                    currentColor: ps.customColorName,
                    defaultLabel: "기본 (\(provider.colorName))"
                ) { color in
                    var updated = ps
                    updated.customColorName = color
                    settings.providerSettingsMap[provider.id] = updated
                }
            }

            Picker("스타일", selection: Binding(
                get: { ps.animationStyle ?? settings.animationStyle },
                set: { newVal in
                    var updated = ps
                    updated.animationStyle = newVal == settings.animationStyle ? nil : newVal
                    settings.providerSettingsMap[provider.id] = updated
                }
            )) {
                Text("캐릭터").tag(AnimationStyle.character)
                Text("수치").tag(AnimationStyle.numeric)
                Text("그래프").tag(AnimationStyle.sparkline)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private func colorPickerMenu(
        currentColor: String?,
        defaultLabel: String,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            Button(action: { onSelect(nil) }) {
                HStack {
                    Text(defaultLabel)
                    if currentColor == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(ProviderInfo.availableColors, id: \.name) { color in
                Button(action: { onSelect(color.name) }) {
                    HStack {
                        Circle()
                            .fill(ProviderInfo.colorFromName(color.name))
                            .frame(width: 10, height: 10)
                        Text(color.displayName)
                        if currentColor == color.name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(currentColor.map { ProviderInfo.colorFromName($0) } ?? .white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                Text(colorDisplayName(currentColor, defaultLabel: defaultLabel))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func colorDisplayName(_ currentColor: String?, defaultLabel: String) -> String {
        if let colorName = currentColor {
            return ProviderInfo.availableColors.first { $0.name == colorName }?.displayName ?? colorName
        }
        return defaultLabel
    }
}
