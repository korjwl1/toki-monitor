import SwiftUI

struct ProvidersSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("활성화") {
                ForEach(ProviderRegistry.configurableProviders) { provider in
                    providerRow(provider)
                }
            }

            if settings.providerDisplayMode == .perProvider {
                Section("개별 스타일") {
                    let enabledProviders = ProviderRegistry.configurableProviders.filter {
                        settings.effectiveSettings(for: $0.id).enabled
                    }

                    if enabledProviders.isEmpty {
                        Text("활성화된 프로바이더가 없습니다")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(enabledProviders) { provider in
                            individualProviderRow(provider)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func providerRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)

        return Toggle(isOn: Binding(
            get: { ps.enabled },
            set: { newVal in
                settings.setProviderEnabled(
                    provider.id,
                    enabled: newVal,
                    tokiProviderId: provider.tokiProviderId
                )
            }
        )) {
            Label(provider.name, systemImage: provider.icon)
                .foregroundStyle(provider.color)
        }
    }

    private func individualProviderRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)
        let customColor = ps.customColorName ?? provider.colorName

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(provider.name, systemImage: provider.icon)
                    .foregroundStyle(ProviderInfo.colorFromName(customColor))
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
            HStack(spacing: 4) {
                Circle()
                    .fill(currentColor.map { ProviderInfo.colorFromName($0) } ?? .white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
