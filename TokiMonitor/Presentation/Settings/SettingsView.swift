import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("설정")
                    .font(.headline)

                Divider()

                menuBarStyleSection
                Divider()
                providerSection
                Divider()
                miscSection
            }
            .padding(16)
        }
        .frame(width: 300)
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

            // Character options
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

            // Token unit
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

            // Graph time range
            if settings.animationStyle == .sparkline {
                settingRow("그래프 시간폭") {
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
    }

    private var shouldShowTokenUnit: Bool {
        settings.animationStyle == .numeric ||
        (settings.animationStyle == .character && settings.showRateText)
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("프로바이더")

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

                    Menu {
                        Button(action: { settings.aggregatedColorName = nil }) {
                            HStack {
                                Text("기본 (흰색)")
                                if settings.aggregatedColorName == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach(ProviderInfo.availableColors, id: \.name) { color in
                            Button(action: { settings.aggregatedColorName = color.name }) {
                                HStack {
                                    Circle()
                                        .fill(ProviderInfo.colorFromName(color.name))
                                        .frame(width: 10, height: 10)
                                    Text(color.displayName)
                                    if settings.aggregatedColorName == color.name {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let colorName = settings.aggregatedColorName {
                                Circle()
                                    .fill(ProviderInfo.colorFromName(colorName))
                                    .frame(width: 12, height: 12)
                            } else {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            } else {
                // 개별 모드 — 프로바이더별 설정
                ForEach(ProviderRegistry.configurableProviders) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerRow(_ provider: ProviderInfo) -> some View {
        let ps = settings.effectiveSettings(for: provider.id)
        let customColor = ps.customColorName ?? provider.colorName

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { ps.enabled },
                    set: { newVal in
                        var updated = ps
                        updated.enabled = newVal
                        settings.providerSettingsMap[provider.id] = updated
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Image(systemName: provider.icon)
                    .foregroundStyle(ProviderInfo.colorFromName(customColor))
                    .frame(width: 16)

                Text(provider.name)
                    .font(.system(size: 12, weight: .medium))

                Spacer()

                // Color picker
                Menu {
                    ForEach(ProviderInfo.availableColors, id: \.name) { color in
                        Button(action: {
                            var updated = ps
                            updated.customColorName = color.name == provider.colorName ? nil : color.name
                            settings.providerSettingsMap[provider.id] = updated
                        }) {
                            HStack {
                                Circle()
                                    .fill(ProviderInfo.colorFromName(color.name))
                                    .frame(width: 10, height: 10)
                                Text(color.displayName)
                                if customColor == color.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Circle()
                        .fill(ProviderInfo.colorFromName(customColor))
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
                        )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            if ps.enabled {
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

    /// Label + control in a consistent row layout
    private func settingRow<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            control()
        }
    }
}
