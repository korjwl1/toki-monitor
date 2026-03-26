import SwiftUI

struct NotificationsSettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var expandUsage75 = false
    @State private var expandUsage90 = false
    @State private var chevronExpanded75 = false
    @State private var chevronExpanded90 = false

    var body: some View {
        Form {
            Section {
                alertZStack(
                    title: L.notification.alert75,
                    threshold: .percent75,
                    isExpanded: $expandUsage75,
                    chevronExpanded: $chevronExpanded75,
                    isEnabled: $settings.usageAlert75Enabled
                )
                .onChange(of: settings.usageAlert75Enabled) { _, enabled in
                    withAnimation(.easeInOut(duration: 0.2)) { expandUsage75 = enabled }
                    chevronExpanded75 = enabled
                }
                .background(scrollTopTracker)
            } header: {
                Text(L.notification.usageAlerts)
            }

            Section {
                alertZStack(
                    title: L.notification.alert90,
                    threshold: .percent90,
                    isExpanded: $expandUsage90,
                    chevronExpanded: $chevronExpanded90,
                    isEnabled: $settings.usageAlert90Enabled
                )
                .onChange(of: settings.usageAlert90Enabled) { _, enabled in
                    withAnimation(.easeInOut(duration: 0.2)) { expandUsage90 = enabled }
                    chevronExpanded90 = enabled
                }
            }
        }
        .formStyle(.grouped)
    }

    private func alertZStack(
        title: String,
        threshold: UsageAlertThreshold,
        isExpanded: Binding<Bool>,
        chevronExpanded: Binding<Bool>,
        isEnabled: Binding<Bool>
    ) -> some View {
        ZStack(alignment: .topLeading) {
            // z=0: 원래 구조 그대로, opacity(0)으로 숨김 → 깜빡여도 안 보임
            // 서브아이템은 여기서 애니메이션
            VStack(spacing: 0) {
                usageAlertRow(
                    title: title,
                    isEnabled: isEnabled,
                    isExpanded: isExpanded
                )
                .opacity(0)

                if isExpanded.wrappedValue {
                    VStack(spacing: 0) {
                        usageBucketToggles(for: threshold)
                    }
                    .disabled(!isEnabled.wrappedValue)
                    .opacity(isEnabled.wrappedValue ? 1 : 0.5)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
            .clipped()

            // z=1: 안정적인 헤더 — chevronExpanded만 읽음, withAnimation 범위와 무관
            usageAlertRow(
                title: title,
                isEnabled: isEnabled,
                chevronExpanded: chevronExpanded.wrappedValue,
                onChevronTap: {
                    let next = !isExpanded.wrappedValue
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue = next }
                    chevronExpanded.wrappedValue = next
                }
            )
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    // z=0용: 원래 usageAlertRow (isExpanded binding 사용)
    private func usageAlertRow(
        title: String,
        isEnabled: Binding<Bool>,
        isExpanded: Binding<Bool>
    ) -> some View {
        HStack(spacing: DS.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
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

    // z=1용: chevronExpanded(별도 state)만 읽음 — withAnimation에 반응 안 함
    private func usageAlertRow(
        title: String,
        isEnabled: Binding<Bool>,
        chevronExpanded: Bool,
        onChevronTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.sm) {
            Button(action: onChevronTap) {
                HStack(spacing: 6) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Image(systemName: chevronExpanded ? "chevron.down" : "chevron.right")
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
