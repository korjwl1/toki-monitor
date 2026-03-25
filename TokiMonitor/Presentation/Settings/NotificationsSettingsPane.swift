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
                }
            }
        }
        .formStyle(.grouped)
    }
}
