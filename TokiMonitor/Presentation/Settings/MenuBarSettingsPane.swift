import SwiftUI

struct MenuBarSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section(L.menuBar.animation) {
                Picker(L.menuBar.style, selection: $settings.animationStyle) {
                    Text(L.menuBar.character).tag(AnimationStyle.character)
                    Text(L.menuBar.numeric).tag(AnimationStyle.numeric)
                    Text(L.menuBar.graph).tag(AnimationStyle.sparkline)
                }
                .pickerStyle(.segmented)

                if settings.animationStyle == .character {
                    Toggle(L.menuBar.showRateText, isOn: $settings.showRateText)

                    if settings.showRateText {
                        Picker(L.menuBar.textPosition, selection: $settings.textPosition) {
                            ForEach(TextPosition.allCases, id: \.self) { pos in
                                Text(pos.displayName).tag(pos)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                if shouldShowTokenUnit {
                    Picker(L.menuBar.unit, selection: $settings.tokenUnit) {
                        ForEach(TokenUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Picker(L.menuBar.sparklineTimeRange, selection: $settings.graphTimeRange) {
                    ForEach(GraphTimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L.menuBar.displayMode) {
                Picker(L.menuBar.mode, selection: $settings.providerDisplayMode) {
                    ForEach(ProviderDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settings.providerDisplayMode == .aggregated {
                    HStack {
                        Text(L.menuBar.iconColor)
                        Spacer()
                        colorPickerMenu(
                            currentColor: settings.aggregatedColorName,
                            defaultLabel: L.menuBar.defaultWhite
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
