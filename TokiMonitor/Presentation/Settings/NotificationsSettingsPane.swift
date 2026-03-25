import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var expandUsage75 = false
    @State private var expandUsage90 = false

    var body: some View {
        Form {
            Section {
                usageAlertRow(
                    title: L.notification.alert75,
                    isEnabled: $settings.usageAlert75Enabled,
                    isExpanded: $expandUsage75
                )
                .onChange(of: settings.usageAlert75Enabled) { _, enabled in
                    expandUsage75 = enabled
                }

                if expandUsage75 {
                    usageBucketToggles(for: .percent75)
                        .disabled(!settings.usageAlert75Enabled)
                        .opacity(settings.usageAlert75Enabled ? 1 : 0.5)
                }
            } header: {
                Text(L.notification.usageAlerts)
            }

            Section {
                usageAlertRow(
                    title: L.notification.alert90,
                    isEnabled: $settings.usageAlert90Enabled,
                    isExpanded: $expandUsage90
                )
                .onChange(of: settings.usageAlert90Enabled) { _, enabled in
                    expandUsage90 = enabled
                }

                if expandUsage90 {
                    usageBucketToggles(for: .percent90)
                        .disabled(!settings.usageAlert90Enabled)
                        .opacity(settings.usageAlert90Enabled ? 1 : 0.5)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func usageBucketToggles(for threshold: UsageAlertThreshold) -> some View {
        Group {
            indentedRow(Toggle(
                UsageAlertBucket.claudeFiveHour.displayName,
                isOn: usageBucketBinding(threshold, .claudeFiveHour)
            ))
            indentedRow(Toggle(
                UsageAlertBucket.claudeSevenDay.displayName,
                isOn: usageBucketBinding(threshold, .claudeSevenDay)
            ))
            indentedRow(
                Toggle(
                    UsageAlertBucket.claudeSevenDaySonnet.displayName,
                    isOn: usageBucketBinding(threshold, .claudeSevenDaySonnet)
                )
                .disabled(settings.claudeHasSevenDaySonnet == false)
                .opacity(settings.claudeHasSevenDaySonnet == false ? 0.45 : 1)
            )
            indentedRow(Toggle(
                UsageAlertBucket.codexPrimary.displayName,
                isOn: usageBucketBinding(threshold, .codexPrimary)
            ))
            indentedRow(
                Toggle(
                    UsageAlertBucket.codexSecondary.displayName,
                    isOn: usageBucketBinding(threshold, .codexSecondary)
                )
                .disabled(settings.codexHasSecondaryWindow == false)
                .opacity(settings.codexHasSecondaryWindow == false ? 0.45 : 1)
            )
        }
    }

    private func usageAlertRow(
        title: String,
        isEnabled: Binding<Bool>,
        isExpanded: Binding<Bool>
    ) -> some View {
        HStack(spacing: DS.sm) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: isEnabled)
                .labelsHidden()
        }
    }

    private func indentedRow<Content: View>(_ content: Content) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 16)
            content
        }
    }


    private func usageBucketBinding(
        _ threshold: UsageAlertThreshold,
        _ bucket: UsageAlertBucket
    ) -> Binding<Bool> {
        Binding(
            get: { settings.isUsageAlertBucketEnabled(threshold, bucket: bucket) },
            set: { settings.setUsageAlertBucketEnabled(threshold, bucket: bucket, enabled: $0) }
        )
    }

}
