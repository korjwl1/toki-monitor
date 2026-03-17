import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("설정")
                .font(.headline)

            Divider()

            // Animation style
            VStack(alignment: .leading, spacing: 6) {
                Text("메뉴바 스타일")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("", selection: $settings.animationStyle) {
                    Text("캐릭터").tag(AnimationStyle.character)
                    Text("수치").tag(AnimationStyle.numeric)
                    Text("그래프").tag(AnimationStyle.sparkline)
                }
                .pickerStyle(.segmented)
            }

            // Default time range
            VStack(alignment: .leading, spacing: 6) {
                Text("기본 시간 범위")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("", selection: $settings.defaultTimeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Launch at login
            Toggle("로그인 시 자동 시작", isOn: $settings.launchAtLogin)

            Divider()

            // About
            HStack {
                Text("Toki Monitor v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("종료") {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
