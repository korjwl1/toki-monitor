import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(L.notification.alert75, isOn: $settings.usageAlert75Enabled)
                    .background(scrollTopTracker)

                if settings.usageAlert75Enabled {
                    usageBucketToggles(for: .percent75)
                }
            } header: {
                Text(L.notification.usageAlerts)
            }

            Section {
                Toggle(L.notification.alert90, isOn: $settings.usageAlert90Enabled)

                if settings.usageAlert90Enabled {
                    usageBucketToggles(for: .percent90)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func usageBucketToggles(for threshold: UsageAlertThreshold) -> some View {
        Toggle(
            UsageAlertBucket.claudeFiveHour.displayName,
            isOn: usageBucketBinding(threshold, .claudeFiveHour)
        )
        Toggle(
            UsageAlertBucket.claudeSevenDay.displayName,
            isOn: usageBucketBinding(threshold, .claudeSevenDay)
        )
        Toggle(
            UsageAlertBucket.claudeSevenDaySonnet.displayName,
            isOn: usageBucketBinding(threshold, .claudeSevenDaySonnet)
        )
        .disabled(settings.claudeHasSevenDaySonnet == false)
        .opacity(settings.claudeHasSevenDaySonnet == false ? 0.45 : 1)
        Toggle(
            UsageAlertBucket.codexPrimary.displayName,
            isOn: usageBucketBinding(threshold, .codexPrimary)
        )
        Toggle(
            UsageAlertBucket.codexSecondary.displayName,
            isOn: usageBucketBinding(threshold, .codexSecondary)
        )
        .disabled(settings.codexHasSecondaryWindow == false)
        .opacity(settings.codexHasSecondaryWindow == false ? 0.45 : 1)
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
