import SwiftUI

/// Rate limit usage bars shown in the menu dropdown.
struct ClaudeUsageSection: View {
    let monitor: ClaudeUsageMonitor

    var body: some View {
        if let usage = monitor.currentUsage {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Claude 사용량")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                }

                if let fiveHour = usage.fiveHour {
                    usageBar(label: "5시간 세션", bucket: fiveHour)
                }
                if let sevenDay = usage.sevenDay {
                    usageBar(label: "7일 주간", bucket: sevenDay)
                }
                if let sonnet = usage.sevenDaySonnet {
                    usageBar(label: "7일 Sonnet", bucket: sonnet)
                }
                if usage.extraUsage?.isEnabled == true {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                        Text("확장 사용량 활성")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func usageBar(label: String, bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer()
                Text("\(Int(bucket.utilization))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: bucket.utilization))
                        .frame(width: geo.size.width * min(bucket.utilization / 100, 1.0))
                }
            }
            .frame(height: 6)

            Text("초기화: \(bucket.resetCountdown)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func barColor(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 75 { return .orange }
        if utilization >= 50 { return .yellow }
        return .green
    }
}
