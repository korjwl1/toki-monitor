import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let oauthManager: ClaudeOAuthManager?
    var onClose: (() -> Void)?

    var body: some View {
        Form {
            if let oauthManager {
                Section("Claude 계정") {
                    ClaudeAccountSection(oauthManager: oauthManager, settings: settings)
                }
            }

            Section("프로바이더") {
                ForEach(ProviderRegistry.configurableProviders) { provider in
                    globalProviderRow(provider)
                }
            }

            Section("메뉴바 스타일") {
                Picker("애니메이션", selection: $settings.animationStyle) {
                    Text("캐릭터").tag(AnimationStyle.character)
                    Text("수치").tag(AnimationStyle.numeric)
                    Text("그래프").tag(AnimationStyle.sparkline)
                }
                .pickerStyle(.segmented)

                if settings.animationStyle == .character {
                    Toggle("캐릭터 옆 토큰 수치 표시", isOn: $settings.showRateText)

                    if settings.showRateText {
                        Picker("텍스트 위치", selection: $settings.textPosition) {
                            ForEach(TextPosition.allCases, id: \.self) { pos in
                                Text(pos.displayName).tag(pos)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if shouldShowTokenUnit {
                    Picker("단위", selection: $settings.tokenUnit) {
                        ForEach(TokenUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Picker("스파크라인 시간폭", selection: $settings.graphTimeRange) {
                    ForEach(GraphTimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("표시 모드") {
                Picker("모드", selection: $settings.providerDisplayMode) {
                    ForEach(ProviderDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.providerDisplayMode == .aggregated {
                    HStack {
                        Text("아이콘 색상")
                        Spacer()
                        colorPickerMenu(
                            currentColor: settings.aggregatedColorName,
                            defaultLabel: "기본 (흰색)"
                        ) { color in
                            settings.aggregatedColorName = color
                        }
                    }
                } else {
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

            Section("일반") {
                Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

                HStack {
                    Text("Toki Monitor v0.1.0")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("닫기") {
                        onClose?()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 400)
    }

    // MARK: - Provider Section

    private var shouldShowTokenUnit: Bool {
        settings.animationStyle == .numeric ||
        (settings.animationStyle == .character && settings.showRateText)
    }

    private func globalProviderRow(_ provider: ProviderInfo) -> some View {
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

    // MARK: - Color Picker

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
