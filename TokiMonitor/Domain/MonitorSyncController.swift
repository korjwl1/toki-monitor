import Foundation
import UserNotifications

/// The settings sync channel as the UI sees it: a switch, a status, and a list
/// of things waiting for a decision.
///
/// Everything that can lose data lives in `MonitorSyncEngine`; this holds the
/// state a view binds to and makes sure a pulled preference reaches the live
/// `AppSettings` rather than sitting in `UserDefaults` waiting to be overwritten.
@MainActor
@Observable
final class MonitorSyncController {
    static let shared = MonitorSyncController()

    private(set) var isRunning = false
    /// What the last run did. nil until one has run in this session.
    private(set) var lastOutcome: MonitorSyncOutcome?
    /// Decisions still owed by the user. They are not cleared by time or by a
    /// later run — only by being resolved.
    private(set) var conflicts: [MonitorSyncConflict] = []

    private let engine: MonitorSyncEngine
    private let settings: () -> AppSettings?
    private var timer: Timer?
    /// Conflicts the user has already been told about, so a repeating sync does
    /// not repeat the notification every quarter of an hour.
    private var announced: Set<String> = []

    init(engine: MonitorSyncEngine? = nil,
         settings: @escaping () -> AppSettings? = { L.settings }) {
        self.engine = engine ?? MonitorSyncEngine(
            transport: MonitorSettingsClient(),
            store: DashboardConfigStore(),
            defaults: .standard
        )
        self.settings = settings
        self.conflicts = []
    }

    var isEnabled: Bool { engine.isEnabled }
    var lastRun: Date? { engine.lastRun }

    // MARK: - Running on its own

    /// Reconcile at launch and then periodically.
    ///
    /// A channel that only ran when someone happened to open Settings would
    /// mean a dashboard edited on the other Mac stays there. The interval is
    /// long because the payload is configuration: it changes when a person
    /// changes it, not continuously.
    func start(interval: TimeInterval = 900) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                await self.syncNow()
            }
        }
        guard isEnabled else { return }
        Task { await syncNow() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// What the user is agreeing to. Shown at the opt-in, not buried in a
    /// help page — the query strings in a dashboard are the user's own words
    /// and often name their projects and the models they use.
    static var disclosure: String {
        L.tr("""
             대시보드 정의와 모니터 표시 설정이 sync 서버의 내 계정에 저장됩니다. \
             질의 결과·사용량·비용 수치는 올라가지 않지만, 질의 문자열은 쓴 그대로 올라가므로 \
             프로젝트명과 모델명이 이 컴퓨터를 떠납니다. \
             데이터소스 정의와 로그인 항목 설정은 이 기기에만 남습니다.
             """,
             """
             Your dashboard definitions and monitor display settings are stored in your account \
             on the sync server. No query results, usage or cost figures go up — but query \
             strings go up as written, so your project and model names leave this computer. \
             Datasource definitions and the launch-at-login setting stay on this machine.
             """)
    }

    // MARK: - The switch

    /// Turn the channel on and reconcile once.
    ///
    /// The first run is where a machine that already has dashboards meets a
    /// server that already has dashboards, and it adds rather than replaces:
    /// anything the two sides disagree about comes back as a conflict for the
    /// user to settle.
    func enable() async {
        engine.isEnabled = true
        await syncNow()
    }

    /// Turn it off. Nothing local is removed, and nothing on the server is
    /// either — a switch is not a request to delete.
    func disable() {
        engine.disable()
        conflicts = []
        announced = []
        lastOutcome = nil
    }

    // MARK: - Running

    func syncNow() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let outcome = await engine.sync()
        lastOutcome = outcome
        merge(conflicts: outcome.conflicts)
        if outcome.pulled.contains(MonitorSyncKey.preferences) {
            settings()?.reloadFromDefaults()
        }
    }

    /// Carry out the user's decision about one conflict.
    func resolve(_ conflict: MonitorSyncConflict, with resolution: MonitorSyncResolution) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let outcome = await engine.resolve(conflict, with: resolution)
        if outcome.problems.isEmpty {
            conflicts.removeAll { $0.key == conflict.key }
        }
        lastOutcome = outcome
        if outcome.pulled.contains(MonitorSyncKey.preferences) {
            settings()?.reloadFromDefaults()
        }
    }

    // MARK: - Helpers

    /// Replace what a run found, keeping the order stable so a list on screen
    /// does not reshuffle under the user's cursor mid-decision.
    private func merge(conflicts new: [MonitorSyncConflict]) {
        var merged = new
        merged.sort { $0.key < $1.key }
        conflicts = merged

        // A sync that runs on a timer can find a disagreement while the user is
        // doing something else entirely. Leaving it to be discovered the next
        // time they open Settings is how one of the two copies eventually gets
        // lost by accident.
        let unannounced = Set(merged.map(\.key)).subtracting(announced)
        announced = Set(merged.map(\.key))
        guard !unannounced.isEmpty else { return }
        notifyOfConflicts(count: merged.count)
    }

    private func notifyOfConflicts(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = L.monitorSync.conflictNotificationTitle
        content.body = L.monitorSync.conflictNotificationBody(count)
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "toki-monitor-sync-conflicts",
                                  content: content, trigger: nil)
        )
    }
}
