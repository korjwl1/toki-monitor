import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let oauthManager: ClaudeOAuthManager?
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("설정")
                    .font(.headline)

                Divider()

                if let oauthManager {
                    ClaudeAccountSection(oauthManager: oauthManager, settings: settings)
                    Divider()
                }

                providerSection
                Divider()
                menuBarStyleSection
                Divider()
                displayModeSection
                Divider()
                miscSection
            }
            .padding(16)
        }
        .frame(width: 300)
    }

    // MARK: - Provider Section (Global)

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("프로바이더")

            ForEach(ProviderRegistry.configurableProviders) { provider in
                globalProviderRow(provider)
            }
        }
    }

    private func globalProviderRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { ps.enabled },
                set: { newVal in
                    settings.setProviderEnabled(
                        provider.id,
                        enabled: newVal,
                        tokiProviderId: provider.tokiProviderId
                    )
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: provider.icon)
                .foregroundStyle(provider.color)
                .frame(width: 16)

            Text(provider.name)
                .font(.system(size: 12, weight: .medium))

            Spacer()
        }
    }

    // MARK: - Menu Bar Style

    private var menuBarStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("메뉴바 스타일")

            Picker("", selection: $settings.animationStyle) {
                Text("캐릭터").tag(AnimationStyle.character)
                Text("수치").tag(AnimationStyle.numeric)
                Text("그래프").tag(AnimationStyle.sparkline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.animationStyle == .character {
                Toggle("캐릭터 옆 토큰 수치 표시", isOn: $settings.showRateText)
                    .font(.system(size: 12))

                if settings.showRateText {
                    settingRow("텍스트 위치") {
                        Picker("", selection: $settings.textPosition) {
                            ForEach(TextPosition.allCases, id: \.self) { pos in
                                Text(pos.displayName).tag(pos)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            if shouldShowTokenUnit {
                settingRow("단위") {
                    Picker("", selection: $settings.tokenUnit) {
                        ForEach(TokenUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            settingRow("스파크라인 시간폭") {
                Picker("", selection: $settings.graphTimeRange) {
                    ForEach(GraphTimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var shouldShowTokenUnit: Bool {
        settings.animationStyle == .numeric ||
        (settings.animationStyle == .character && settings.showRateText)
    }

    // MARK: - Display Mode Section

    private var displayModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("표시 모드")

            Picker("", selection: $settings.providerDisplayMode) {
                ForEach(ProviderDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.providerDisplayMode == .aggregated {
                // 합산 아이콘 색상
                HStack(spacing: 8) {
                    Text("아이콘 색상")
                        .font(.system(size: 12))
                    Spacer()
                    colorPickerMenu(
                        currentColor: settings.aggregatedColorName,
                        defaultLabel: "기본 (흰색)"
                    ) { color in
                        settings.aggregatedColorName = color
                    }
                }
            } else {
                // 개별 모드 — 활성화된 프로바이더만 개별 설정
                let enabledProviders = ProviderRegistry.configurableProviders.filter {
                    settings.effectiveSettings(for: $0.id).enabled
                }

                if enabledProviders.isEmpty {
                    Text("활성화된 프로바이더가 없습니다")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(enabledProviders) { provider in
                        individualProviderRow(provider)
                    }
                }
            }
        }
    }

    private func individualProviderRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)
        let customColor = ps.customColorName ?? provider.colorName

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: provider.icon)
                    .foregroundStyle(ProviderInfo.colorFromName(customColor))
                    .frame(width: 16)

                Text(provider.name)
                    .font(.system(size: 12, weight: .medium))

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

            HStack(spacing: 4) {
                Text("스타일")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)
                Picker("", selection: Binding(
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
                .labelsHidden()
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Misc

    private var miscSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            HStack {
                Text("Toki Monitor v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기") {
                    onClose?()
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func settingRow<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            control()
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
            if let colorName = currentColor {
                Circle()
                    .fill(ProviderInfo.colorFromName(colorName))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
            } else {
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 24)
    }
}
