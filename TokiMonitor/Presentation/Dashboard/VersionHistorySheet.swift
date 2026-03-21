import SwiftUI

/// Shows dashboard version history with diff and restore capabilities.
struct VersionHistorySheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedVersion: DashboardVersion?
    @State private var compareVersion: DashboardVersion?
    @State private var showDiff = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.dash.versions)
                    .font(.headline)
                Spacer()
                Button(L.dash.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if showDiff, let v1 = selectedVersion, let v2 = compareVersion {
                diffView(v1: v1, v2: v2)
            } else {
                versionList
            }
        }
        .frame(width: 520, height: 400)
    }

    private var versionList: some View {
        let versions = viewModel.versionStore.versions(for: viewModel.dashboardConfig.uid)

        return Group {
            if versions.isEmpty {
                ContentUnavailableView(
                    L.tr("버전 기록이 없습니다", "No version history"),
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List(versions) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("v\(version.version)")
                                .font(.subheadline.bold())
                            Text(version.timestamp, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(version.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !version.message.isEmpty {
                                Text(version.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Compare button
                        Button {
                            if selectedVersion == nil {
                                selectedVersion = version
                            } else {
                                compareVersion = version
                                showDiff = true
                            }
                        } label: {
                            Text(selectedVersion == nil ? L.dash.compare : L.tr("비교 대상", "Compare with"))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)

                        // Restore button
                        Button {
                            let restored = viewModel.versionStore.restoreVersion(version)
                            viewModel.switchDashboard(restored)
                            dismiss()
                        } label: {
                            Text(L.dash.restore)
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
    }

    private func diffView(v1: DashboardVersion, v2: DashboardVersion) -> some View {
        let diffs = viewModel.versionStore.diffVersions(v1, v2)

        return VStack(spacing: 0) {
            HStack {
                Button {
                    showDiff = false
                    selectedVersion = nil
                    compareVersion = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L.tr("뒤로", "Back"))
                    }
                }
                .buttonStyle(.plain)

                Text("v\(v1.version) -> v\(v2.version)")
                    .font(.subheadline.bold())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if diffs.isEmpty {
                ContentUnavailableView(
                    L.tr("변경 사항 없음", "No changes"),
                    systemImage: "checkmark.circle"
                )
            } else {
                List(Array(diffs.enumerated()), id: \.offset) { _, diff in
                    HStack {
                        Text(diff.field)
                            .font(.caption.bold())
                            .frame(width: 100, alignment: .leading)
                        Text(diff.old)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(diff.new)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
