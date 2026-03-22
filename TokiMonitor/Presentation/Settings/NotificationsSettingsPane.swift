import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var showVelocityInfo = false
    @State private var showHistoricalInfo = false

    var body: some View {
        Form {
            Section(L.notification.claudeUsageAlerts) {
                Toggle(L.notification.alert75, isOn: $settings.claudeAlert75)
                Toggle(L.notification.alert90, isOn: $settings.claudeAlert90)
            }

            // Velocity alert
            Section {
                Toggle(isOn: $settings.velocityAlertEnabled) {
                    HStack(spacing: DS.xs) {
                        Text(L.notification.velocityAlert)
                        Button {
                            showVelocityInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showVelocityInfo, arrowEdge: .bottom) {
                            Text(L.notification.velocityDesc)
                                .font(.system(size: DS.fontCaption))
                                .padding(DS.md)
                                .frame(width: 240)
                        }
                    }
                }

                if settings.velocityAlertEnabled {
                    HStack {
                        Text(L.notification.velocityThreshold)
                        Spacer()
                        TextField("", value: $settings.velocityThreshold, format: .number.precision(.fractionLength(2)))
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker(L.tr("경고 방식", "Alert Method"), selection: $settings.velocityAlertMode) {
                        ForEach(AlertMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.velocityAlertMode != .notification {
                        alertColorPicker(
                            selection: $settings.velocityAlertColor,
                            label: L.tr("경고 색상", "Alert Color")
                        )
                    }
                }
            } header: {
                Text(L.notification.anomalyDetection)
            }

            // Historical alert
            Section {
                Toggle(isOn: $settings.historicalAlertEnabled) {
                    HStack(spacing: DS.xs) {
                        Text(L.notification.historicalAlert)
                        Button {
                            showHistoricalInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showHistoricalInfo, arrowEdge: .bottom) {
                            Text(L.notification.historicalDesc)
                                .font(.system(size: DS.fontCaption))
                                .padding(DS.md)
                                .frame(width: 260)
                        }
                    }
                }

                if settings.historicalAlertEnabled {
                    HStack {
                        Text(L.notification.historicalMultiplier)
                        Spacer()
                        TextField("", value: $settings.historicalMultiplier, format: .number.precision(.fractionLength(1)))
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker(L.tr("경고 방식", "Alert Method"), selection: $settings.historicalAlertMode) {
                        ForEach(AlertMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.historicalAlertMode != .notification {
                        alertColorPicker(
                            selection: $settings.historicalAlertColor,
                            label: L.tr("경고 색상", "Alert Color")
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func alertColorPicker(selection: Binding<String>, label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Menu {
                ForEach(ProviderInfo.availableColors, id: \.name) { color in
                    Button {
                        selection.wrappedValue = color.name
                    } label: {
                        HStack {
                            Circle()
                                .fill(ProviderInfo.colorFromName(color.name))
                                .frame(width: 10, height: 10)
                            Text(color.displayName)
                            if selection.wrappedValue == color.name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ProviderInfo.colorFromName(selection.wrappedValue))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                    Text(ProviderInfo.availableColors.first { $0.name == selection.wrappedValue }?.displayName ?? selection.wrappedValue)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
