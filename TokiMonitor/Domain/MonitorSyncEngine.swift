import Foundation
import CryptoKit

// MARK: - Syncing the monitor's own configuration
//
// The rule this whole file exists to keep:
//
//   A sync never replaces local state the user has not seen.
//
// Everything below follows from it. A pull only ADDS what is not here, or
// applies a change to something this machine already agreed on. Anything else
// — two sides that both moved, a first sync where the two sides already differ,
// a write that lost a race — stops and asks. There is no "server wins" and no
// "last write wins", because both of those are ways of saying that somebody's
// afternoon of work is gone and nobody was told.

// MARK: - Ledger

/// What this machine and the server last agreed on, per key.
///
/// Two facts, and both are needed. `version` says where the server was, so a
/// write can be a compare-and-swap instead of a blind overwrite. `hash` says
/// what the bytes were, so a local edit can be told from a local no-op — the
/// version alone cannot, and without it every sync would push every dashboard.
struct MonitorSyncLedgerEntry: Codable, Equatable {
    var version: Int64
    var hash: String
}

struct MonitorSyncLedger: Codable, Equatable {
    var entries: [String: MonitorSyncLedgerEntry] = [:]

    subscript(key: String) -> MonitorSyncLedgerEntry? {
        get { entries[key] }
        set { entries[key] = newValue }
    }
}

// MARK: - Conflicts

/// One side of a disagreement, described well enough to choose between them
/// without opening either.
struct MonitorSyncSide: Equatable, Sendable {
    var title: String
    var detail: String
    var payload: String
    /// The server version this side is at. nil for the local side.
    var version: Int64?
    var updatedAt: Date?
}

/// A disagreement the user has to settle. Nothing about it is resolved until
/// they do.
struct MonitorSyncConflict: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Both sides moved since they last agreed — or this machine has never
        /// synced this entry and the two sides already differ. The second case
        /// is the first sync on a machine that already has dashboards, and it
        /// is the one that would otherwise quietly overwrite a year of work.
        case divergent
        /// The write lost a race: the server moved between the version this
        /// edit was based on and the moment it landed (HTTP 409).
        case writeRace(serverVersion: Int64)
        /// The entry is gone from the server but is still here. Another machine
        /// deleted it. This machine does NOT follow suit on its own.
        case deletedOnServer
    }

    var id: String { key }
    var key: String
    var kind: Kind
    var local: MonitorSyncSide?
    var remote: MonitorSyncSide?

    var isDashboard: Bool { MonitorSyncKey.isDashboard(key) }

    /// "Keep both" only means something for a document with an identity that
    /// can be duplicated. There is one preferences snapshot, so keeping two
    /// would be keeping neither.
    var canKeepBoth: Bool {
        isDashboard && kind != .deletedOnServer && remote != nil
    }
}

/// What the user decided. There is no default: an unresolved conflict stays
/// unresolved, and is raised again on the next sync.
enum MonitorSyncResolution: Equatable, Sendable {
    /// This machine's copy replaces the server's.
    case keepLocal
    /// The server's copy replaces this machine's.
    case takeRemote
    /// The server's copy is added here as a separate dashboard, and this
    /// machine's keeps the key.
    case keepBoth
    /// Only for `deletedOnServer`: follow the deletion here too.
    case deleteLocal
}

// MARK: - Outcome

struct MonitorSyncProblem: Equatable, Identifiable, Sendable {
    var id: String { key + message }
    var key: String
    var message: String
}

/// What one run did. Every field is something that HAPPENED, not something
/// that was attempted; a problem is a thing that did not happen, and local
/// state is unchanged for it.
struct MonitorSyncOutcome: Equatable, Sendable {
    var pushed: [String] = []
    var pulled: [String] = []
    var deletedOnServer: [String] = []
    var conflicts: [MonitorSyncConflict] = []
    var problems: [MonitorSyncProblem] = []
    var quota: MonitorSettingsQuota?
    /// Set when the run could not start at all — no credentials, server
    /// unreachable, index unreadable. Nothing was read or written either side.
    var failure: String?

    var didChangeAnything: Bool {
        !pushed.isEmpty || !pulled.isEmpty || !deletedOnServer.isEmpty
    }
    var needsAttention: Bool {
        !conflicts.isEmpty || !problems.isEmpty || failure != nil
    }
}

// MARK: - Engine

/// Decides what to push, what to pull, and what to ask about.
///
/// Takes its transport as a protocol and its `UserDefaults` by injection, so
/// the decisions can be proved against a fake server without a network and
/// without going anywhere near the real `com.toki.monitor` domain.
@MainActor
final class MonitorSyncEngine {

    static let enabledKey = "monitorSyncEnabled"
    static let ledgerKey = "monitorSyncLedger"
    static let lastRunKey = "monitorSyncLastRun"

    private let transport: MonitorSettingsTransport
    private let store: DashboardConfigStore
    private let defaults: UserDefaults

    init(transport: MonitorSettingsTransport,
         store: DashboardConfigStore,
         defaults: UserDefaults) {
        self.transport = transport
        self.store = store
        self.defaults = defaults
    }

    // MARK: Opt-in

    /// Off unless the user turned it on. Nothing in this file runs otherwise.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Stop syncing. Local dashboards and preferences are untouched, and so is
    /// what is already on the server — turning a switch off is not a request to
    /// delete anything. The ledger goes, so a later re-enable starts from the
    /// same place a fresh machine would: comparing, not assuming.
    func disable() {
        isEnabled = false
        defaults.removeObject(forKey: Self.ledgerKey)
    }

    var lastRun: Date? {
        let seconds = defaults.double(forKey: Self.lastRunKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    // MARK: - One run

    /// Reconcile this machine with the server.
    ///
    /// Never throws. A failure is an ordinary outcome here — the server is
    /// down, the token expired, there is no network — and every one of them
    /// leaves local state exactly as it was.
    func sync() async -> MonitorSyncOutcome {
        guard isEnabled else { return MonitorSyncOutcome() }

        writesPaused = nil
        var outcome = MonitorSyncOutcome()

        let index: MonitorSettingsIndex
        do {
            index = try await transport.index()
        } catch {
            // Nothing has been read and nothing written. Say so and stop.
            outcome.failure = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return outcome
        }
        outcome.quota = index.quota

        let local = localPayloads(into: &outcome)
        var ledger = loadLedger()

        // Everything that needs applying is decided first and applied after, so
        // that a failure partway through the plan cannot leave half a pull on
        // disk.
        var pullsToApply: [String: MonitorSettingEntry] = [:]

        let keys = Set(local.keys)
            .union(index.entries.map(\.key))
            .union(ledger.entries.keys)

        for key in keys.sorted() {
            let mine = local[key]
            let theirs = index.meta(for: key)
            let agreed = ledger[key]

            switch (mine, theirs, agreed) {

            // Neither side has it any more.
            case (nil, nil, _):
                ledger[key] = nil

            // Here only, never synced: a new dashboard. Create it, and say
            // "expect nothing" so a race with another machine is a conflict
            // rather than a silent overwrite.
            case let (.some(payload), nil, nil):
                await push(key: key, payload: payload, ifVersion: 0,
                           ledger: &ledger, outcome: &outcome)

            // Here, gone there, but we had agreed on it: another machine
            // deleted it. Deleting it here too would destroy a document the
            // user of THIS machine may still want, so it is a question.
            case let (.some(payload), nil, .some):
                outcome.conflicts.append(
                    conflict(key: key, kind: .deletedOnServer, localPayload: payload, remote: nil)
                )

            // Gone here, still there, and we had agreed on it: deleted here.
            // Push the deletion.
            //
            // Dashboards only. The preferences snapshot has no "deleted"
            // state — it is absent from `localPayloads` when this machine has
            // set no preferences at all — and reading that absence as a
            // deletion would wipe the other machines' settings.
            case (nil, .some, .some):
                guard key != MonitorSyncKey.preferences else { break }
                do {
                    try await transport.delete(key: key)
                    outcome.deletedOnServer.append(key)
                    ledger[key] = nil
                } catch MonitorSyncError.notFound {
                    ledger[key] = nil
                } catch {
                    outcome.problems.append(problem(key, error))
                }

            // Gone here, there, and never agreed: an entry from another
            // machine. Taking it adds a dashboard and replaces nothing, so it
            // is safe to do without asking.
            case let (nil, .some(meta), nil):
                await stagePull(key: key, meta: meta, into: &pullsToApply, outcome: &outcome)

            // Both sides have it.
            case let (.some(payload), .some(meta), agreed):
                let mineHash = Self.hash(payload)

                guard let agreed else {
                    // Never synced this key, and both sides have it. This is
                    // the first sync on a machine that already has dashboards.
                    // Identical bytes need no decision; different bytes are
                    // never resolved by guessing which machine matters more.
                    let remote: MonitorSettingEntry
                    do { remote = try await transport.get(key: key) }
                    catch { outcome.problems.append(problem(key, error)); continue }

                    if Self.hash(remote.value) == mineHash {
                        ledger[key] = .init(version: remote.version, hash: mineHash)
                    } else {
                        outcome.conflicts.append(
                            conflict(key: key, kind: .divergent,
                                     localPayload: payload, remote: remote)
                        )
                    }
                    continue
                }

                let changedHere = mineHash != agreed.hash
                let changedThere = meta.version != agreed.version

                switch (changedHere, changedThere) {
                case (false, false):
                    break
                case (true, false):
                    await push(key: key, payload: payload, ifVersion: agreed.version,
                               ledger: &ledger, outcome: &outcome)
                case (false, true):
                    await stagePull(key: key, meta: meta, into: &pullsToApply, outcome: &outcome)
                case (true, true):
                    let remote: MonitorSettingEntry
                    do { remote = try await transport.get(key: key) }
                    catch { outcome.problems.append(problem(key, error)); continue }

                    if Self.hash(remote.value) == mineHash {
                        // Both moved to the same place. Nothing to settle.
                        ledger[key] = .init(version: remote.version, hash: mineHash)
                    } else {
                        outcome.conflicts.append(
                            conflict(key: key, kind: .divergent,
                                     localPayload: payload, remote: remote)
                        )
                    }
                }
            }
        }

        if !pullsToApply.isEmpty {
            applyPulls(pullsToApply, ledger: &ledger, outcome: &outcome)
        }

        saveLedger(ledger)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
        return outcome
    }

    // MARK: - Resolving a conflict

    /// Carry out what the user chose. Anything that fails leaves the conflict
    /// standing — it will be raised again on the next run rather than being
    /// quietly forgotten.
    @discardableResult
    func resolve(_ conflict: MonitorSyncConflict,
                 with resolution: MonitorSyncResolution) async -> MonitorSyncOutcome {
        var outcome = MonitorSyncOutcome()
        var ledger = loadLedger()
        // A decision the user just made is worth one request even if the last
        // bulk run was told to slow down.
        writesPaused = nil

        switch resolution {

        case .keepLocal:
            guard let payload = conflict.local?.payload else {
                outcome.problems.append(.init(key: conflict.key, message: L.tr(
                    "이 기기의 사본을 찾을 수 없습니다", "this machine's copy is no longer here")))
                return outcome
            }
            // The server's CURRENT version, so this write is still a
            // compare-and-swap: the user chose to replace what they were shown,
            // not to replace whatever happens to be there by the time it lands.
            let expected: Int64? = {
                switch conflict.kind {
                case .deletedOnServer: return 0
                case .writeRace(let version): return version
                case .divergent: return conflict.remote?.version
                }
            }()
            await push(key: conflict.key, payload: payload, ifVersion: expected,
                       ledger: &ledger, outcome: &outcome)

        case .takeRemote:
            guard let remote = conflict.remote else {
                outcome.problems.append(.init(key: conflict.key, message: L.tr(
                    "서버 사본을 찾을 수 없습니다", "the server's copy is no longer there")))
                return outcome
            }
            let entry = MonitorSettingEntry(
                key: conflict.key, value: remote.payload,
                version: remote.version ?? 0,
                updatedAt: Int64(remote.updatedAt?.timeIntervalSince1970 ?? 0)
            )
            applyPulls([conflict.key: entry], ledger: &ledger, outcome: &outcome)

        case .keepBoth:
            guard conflict.canKeepBoth, let remote = conflict.remote,
                  let payload = conflict.local?.payload else {
                outcome.problems.append(.init(key: conflict.key, message: L.tr(
                    "이 항목은 둘 다 보관할 수 없습니다", "this entry cannot be kept twice")))
                return outcome
            }
            // The server's copy becomes a second dashboard here, under a new
            // identity so it does not collide with the one it disagreed with.
            do {
                var copy = try MonitorDashboardPayload.decode(remote.payload)
                copy.id = UUID()
                copy.uid = DashboardConfig.generateUID()
                copy.title = L.tr("\(copy.title) (서버 사본)", "\(copy.title) (from server)")
                store.addDashboard(copy)
                if let error = store.lastSaveError {
                    outcome.problems.append(.init(key: conflict.key, message: error))
                    return outcome
                }
                outcome.pulled.append(conflict.key)
            } catch {
                outcome.problems.append(problem(conflict.key, error))
                return outcome
            }
            await push(key: conflict.key, payload: payload,
                       ifVersion: remote.version, ledger: &ledger, outcome: &outcome)

        case .deleteLocal:
            guard conflict.kind == .deletedOnServer,
                  let uid = MonitorSyncKey.dashboardUID(fromKey: conflict.key) else {
                outcome.problems.append(.init(key: conflict.key, message: L.tr(
                    "이 항목은 여기서 삭제할 수 없습니다", "this entry cannot be deleted here")))
                return outcome
            }
            store.deleteDashboard(uid: uid)
            if let error = store.lastSaveError {
                outcome.problems.append(.init(key: conflict.key, message: error))
                return outcome
            }
            ledger[conflict.key] = nil
            outcome.deletedOnServer.append(conflict.key)
        }

        saveLedger(ledger)
        return outcome
    }

    // MARK: - Push

    /// Set when the server asked this client to slow down. The remaining
    /// writes in the run are skipped rather than sent and refused one by one:
    /// the server's budget is per minute, so forty more attempts would all fail
    /// and would fill the screen with forty copies of the same sentence.
    private var writesPaused: MonitorSyncError?

    private func push(key: String, payload: String, ifVersion: Int64?,
                      ledger: inout MonitorSyncLedger,
                      outcome: inout MonitorSyncOutcome) async {
        if let writesPaused {
            outcome.problems.append(problem(key, writesPaused))
            return
        }
        do {
            let write = try await transport.put(key: key, value: payload, ifVersion: ifVersion)
            ledger[key] = .init(version: write.version, hash: Self.hash(payload))
            outcome.pushed.append(key)
        } catch let MonitorSyncError.conflict(_, currentVersion, _) {
            // Lost the race. The other machine's write stands until the user
            // says otherwise; fetching it is what lets them compare.
            var remote: MonitorSettingEntry?
            remote = try? await transport.get(key: key)
            outcome.conflicts.append(
                conflict(key: key, kind: .writeRace(serverVersion: currentVersion),
                         localPayload: payload, remote: remote)
            )
        } catch let error as MonitorSyncError {
            // The ledger is untouched, so this key is simply still unsynced and
            // will be tried again. Nothing local changed.
            if case .rateLimited = error { writesPaused = error }
            outcome.problems.append(problem(key, error))
        } catch {
            outcome.problems.append(problem(key, error))
        }
    }

    // MARK: - Pull

    private func stagePull(key: String, meta: MonitorSettingMeta,
                           into staged: inout [String: MonitorSettingEntry],
                           outcome: inout MonitorSyncOutcome) async {
        do {
            staged[key] = try await transport.get(key: key)
        } catch {
            outcome.problems.append(problem(key, error))
        }
    }

    /// Apply every staged pull, in ONE write per store.
    ///
    /// Decoding happens first, for all of them. A dashboard that will not
    /// decode costs itself and nothing else: it is reported and skipped, and
    /// the list that gets written still contains everything that was already
    /// here. There is no point at which the store holds half a pull.
    private func applyPulls(_ staged: [String: MonitorSettingEntry],
                            ledger: inout MonitorSyncLedger,
                            outcome: inout MonitorSyncOutcome) {
        var decoded: [(entry: MonitorSettingEntry, config: DashboardConfig)] = []

        for (key, entry) in staged.sorted(by: { $0.key < $1.key }) {
            if key == MonitorSyncKey.preferences {
                guard MonitorPrefsSnapshot.apply(entry.value, to: defaults) != nil else {
                    outcome.problems.append(.init(key: key, message: L.tr(
                        "서버의 설정 스냅샷을 읽을 수 없어 적용하지 않았습니다. 이 기기의 설정은 그대로입니다.",
                        "The server's settings snapshot could not be read, so it was not applied. This machine's settings are unchanged."
                    )))
                    continue
                }
                ledger[key] = .init(version: entry.version, hash: Self.hash(entry.value))
                outcome.pulled.append(key)
                continue
            }

            guard MonitorSyncKey.isDashboard(key) else {
                // A key from a build that stores more than this one does. It is
                // left alone rather than guessed at, and left on the server.
                continue
            }
            do {
                decoded.append((entry, try MonitorDashboardPayload.decode(entry.value)))
            } catch {
                outcome.problems.append(problem(key, error))
            }
        }

        guard !decoded.isEmpty else { return }

        var list = store.loadDashboardList()
        for (_, config) in decoded {
            if let index = list.firstIndex(where: { $0.uid == config.uid }) {
                list[index] = config
            } else {
                list.append(config)
            }
        }

        switch store.saveDashboardList(list) {
        case .saved, .keptOriginalBytes:
            for (entry, _) in decoded {
                ledger[entry.key] = .init(version: entry.version, hash: Self.hash(entry.value))
                outcome.pulled.append(entry.key)
            }
        case .failed(let reason):
            // Not one byte was written, and the ledger still says these keys
            // are unsynced, so the next run tries again.
            outcome.problems.append(.init(key: L.tr("대시보드", "dashboards"), message: reason))
        }
    }

    // MARK: - Local side

    /// Everything this machine would put on the server, keyed the way the
    /// server keys it.
    private func localPayloads(into outcome: inout MonitorSyncOutcome) -> [String: String] {
        var payloads: [String: String] = [:]

        for config in store.loadDashboardList() {
            guard let key = MonitorSyncKey.dashboard(uid: config.uid) else {
                outcome.problems.append(.init(key: config.title, message: L.tr(
                    "'\(config.title)'의 식별자(\(config.uid))는 서버 키로 쓸 수 없어 동기화하지 않습니다.",
                    "'\(config.title)' has an identifier (\(config.uid)) that cannot be a server key, so it is not synced."
                )))
                continue
            }
            do {
                payloads[key] = try MonitorDashboardPayload.encode(config)
            } catch {
                outcome.problems.append(problem(config.title, error))
            }
        }

        // A machine where nothing has been configured yet has no preferences to
        // defend, so it takes the server's rather than raising a disagreement
        // between the server and a set of factory defaults.
        if let snapshot = MonitorPrefsSnapshot.capture(from: defaults),
           MonitorPrefsSnapshot.decode(snapshot)?.isEmpty == false {
            payloads[MonitorSyncKey.preferences] = snapshot
        }
        return payloads
    }

    // MARK: - Helpers

    private func conflict(key: String, kind: MonitorSyncConflict.Kind,
                          localPayload: String?, remote: MonitorSettingEntry?) -> MonitorSyncConflict {
        MonitorSyncConflict(
            key: key,
            kind: kind,
            local: localPayload.map { side(key: key, payload: $0, version: nil, updatedAt: nil) },
            remote: remote.map {
                side(key: key, payload: $0.value, version: $0.version,
                     updatedAt: Date(timeIntervalSince1970: TimeInterval($0.updatedAt)))
            }
        )
    }

    /// Describe one side well enough to choose. Titles and counts only — a
    /// conflict sheet is not the place to reprint the user's query strings.
    private func side(key: String, payload: String,
                      version: Int64?, updatedAt: Date?) -> MonitorSyncSide {
        if key == MonitorSyncKey.preferences {
            let count = MonitorPrefsSnapshot.decode(payload)?.count ?? 0
            return MonitorSyncSide(
                title: L.tr("모니터 설정", "Monitor settings"),
                detail: L.tr("설정 \(count)개", "\(count) settings"),
                payload: payload, version: version, updatedAt: updatedAt
            )
        }
        if let config = try? MonitorDashboardPayload.decode(payload) {
            return MonitorSyncSide(
                title: config.title,
                detail: MonitorDashboardPayload.summary(config),
                payload: payload, version: version, updatedAt: updatedAt
            )
        }
        return MonitorSyncSide(
            title: key,
            detail: L.tr("읽을 수 없는 문서", "an unreadable document"),
            payload: payload, version: version, updatedAt: updatedAt
        )
    }

    private func problem(_ key: String, _ error: Error) -> MonitorSyncProblem {
        let message = (error as? DashboardExchange.ImportRefusal)
            .map(DashboardExchange.message(for:))
            ?? (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return MonitorSyncProblem(key: key, message: message)
    }

    /// A stable fingerprint of a payload. Both sides of a comparison come from
    /// `DashboardExchange`, which sorts keys, so identical configuration always
    /// hashes the same and an unchanged dashboard is never pushed.
    static func hash(_ payload: String) -> String {
        SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Ledger persistence

    func loadLedger() -> MonitorSyncLedger {
        guard let data = defaults.data(forKey: Self.ledgerKey),
              let ledger = try? JSONDecoder().decode(MonitorSyncLedger.self, from: data)
        else { return MonitorSyncLedger() }
        return ledger
    }

    private func saveLedger(_ ledger: MonitorSyncLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
    }
}
