import SwiftUI

/// The opt-in for the monitor settings channel, and everything it owes the
/// user afterwards: what left the machine, what came back, and what is waiting
/// on a decision.
///
/// It sits inside `SyncSettingsView` because it needs the same account, but it
/// is a separate switch on purpose. `toki_sync_protocol` carries toki's usage
/// data; this carries the monitor's own configuration. Someone who wants one
/// and not the other must be able to have exactly that.
struct MonitorSyncSettingsSection: View {
    /// Injectable for one reason: rendering this section in a test must not
    /// reach `MonitorSyncController.shared`, which is wired to
    /// `UserDefaults.standard` — and under this test host that IS the live
    /// `com.toki.monitor` domain holding the user's real dashboards. The
    /// default keeps every call site unchanged.
    @State private var controller: MonitorSyncController
    @State private var isEnabled: Bool

    init(controller: MonitorSyncController = .shared) {
        _controller = State(initialValue: controller)
        _isEnabled = State(initialValue: controller.isEnabled)
    }

    @State private var showConflicts = false
    @State private var showTurnOffConfirm = false

    var body: some View {
        Section(L.monitorSync.title) {
            Toggle(isOn: Binding(get: { isEnabled }, set: { turn(on: $0) })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.monitorSync.toggleLabel)
                    Text(MonitorSyncController.disclosure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(controller.isRunning)
            .accessibilityHint(MonitorSyncController.disclosure)

            if isEnabled {
                statusRow
                if !controller.conflicts.isEmpty { conflictRow }
                problemRows
                Button {
                    Task { await controller.syncNow() }
                } label: {
                    Label(L.monitorSync.syncNow, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(controller.isRunning)
            }
        }
        .onAppear {
            // The switch can be turned off from the confirmation below, and the
            // controller is shared, so the row reads the truth rather than
            // whatever this view last remembered.
            isEnabled = controller.isEnabled
        }
        .sheet(isPresented: $showConflicts) {
            MonitorSyncConflictSheet(controller: controller)
        }
        .confirmationDialog(
            L.monitorSync.turnOffTitle,
            isPresented: $showTurnOffConfirm,
            titleVisibility: .visible
        ) {
            Button(L.monitorSync.turnOffConfirm) {
                controller.disable()
                isEnabled = false
            }
            Button(L.tr("취소", "Cancel"), role: .cancel) { isEnabled = true }
        } message: {
            Text(L.monitorSync.turnOffExplanation)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var statusRow: some View {
        LabeledContent(L.monitorSync.lastSync) {
            if controller.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L.monitorSync.running).font(.caption).foregroundStyle(.secondary)
                }
            } else if let outcome = controller.lastOutcome, let failure = outcome.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            } else if let date = controller.lastRun {
                Text(Self.formatter.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L.monitorSync.never).font(.caption).foregroundStyle(.secondary)
            }
        }

        if let outcome = controller.lastOutcome, outcome.didChangeAnything {
            LabeledContent(L.monitorSync.lastResult) {
                Text(L.monitorSync.changeSummary(uploaded: outcome.pushed.count,
                                                 downloaded: outcome.pulled.count,
                                                 removed: outcome.deletedOnServer.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var conflictRow: some View {
        Button {
            showConflicts = true
        } label: {
            HStack {
                Label(L.monitorSync.conflictCount(controller.conflicts.count),
                      systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityHint(L.monitorSync.conflictHint)
    }

    @ViewBuilder
    private var problemRows: some View {
        if let outcome = controller.lastOutcome, !outcome.problems.isEmpty {
            ForEach(outcome.problems) { problem in
                Label(problem.message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func turn(on: Bool) {
        isEnabled = on
        if on {
            Task { await controller.enable() }
        } else {
            showTurnOffConfirm = true
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Conflicts

/// One decision per disagreement, made by the user.
///
/// There is no "resolve all" and no default button. Every option here destroys
/// or duplicates something, and the whole reason this screen exists is that a
/// dashboard edited on another machine must not disappear because a rule picked
/// a side while nobody was looking.
struct MonitorSyncConflictSheet: View {
    let controller: MonitorSyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if controller.conflicts.isEmpty {
                ContentUnavailableView(
                    L.monitorSync.allSettled,
                    systemImage: "checkmark.circle",
                    description: Text(L.monitorSync.allSettledDetail)
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.conflicts) { conflict in
                            MonitorSyncConflictCard(conflict: conflict) { resolution in
                                Task { await controller.resolve(conflict, with: resolution) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text(L.monitorSync.postponeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.tr("닫기", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.monitorSync.conflictTitle).font(.headline)
            Text(L.monitorSync.conflictExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// One disagreement: what is here, what is there, and the choices.
struct MonitorSyncConflictCard: View {
    let conflict: MonitorSyncConflict
    let choose: (MonitorSyncResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(alignment: .top, spacing: 12) {
                if let local = conflict.local {
                    side(L.monitorSync.thisMac, local)
                }
                if let remote = conflict.remote {
                    side(L.monitorSync.theServer, remote)
                }
            }

            HStack(spacing: 8) {
                if conflict.kind == .deletedOnServer {
                    Button(L.monitorSync.keepHere) { choose(.keepLocal) }
                        .buttonStyle(.borderedProminent)
                    Button(L.monitorSync.deleteHereToo, role: .destructive) { choose(.deleteLocal) }
                } else {
                    Button(L.monitorSync.keepThisMac) { choose(.keepLocal) }
                    Button(L.monitorSync.takeTheServers) { choose(.takeRemote) }
                    if conflict.canKeepBoth {
                        Button(L.monitorSync.keepBoth) { choose(.keepBoth) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private func side(_ label: String, _ side: MonitorSyncSide) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(side.title).font(.body)
            Text(side.detail).font(.caption).foregroundStyle(.secondary)
            if let updated = side.updatedAt {
                Text(L.monitorSync.changedAt(Self.formatter.string(from: updated)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let name = conflict.local?.title ?? conflict.remote?.title ?? conflict.key
        switch conflict.kind {
        case .divergent:     return L.monitorSync.divergedHeadline(name)
        case .writeRace:     return L.monitorSync.raceHeadline(name)
        case .deletedOnServer: return L.monitorSync.deletedHeadline(name)
        }
    }

    private var icon: String {
        conflict.kind == .deletedOnServer ? "trash.slash" : "arrow.triangle.branch"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
