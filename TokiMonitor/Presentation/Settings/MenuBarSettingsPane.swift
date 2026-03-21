import SwiftUI

struct MenuBarSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("애니메이션") {
                Picker("스타일", selection: $settings.animationStyle) {
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
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shouldShowTokenUnit: Bool {
        settings.animationStyle == .numeric ||
        (settings.animationStyle == .character && settings.showRateText)
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
