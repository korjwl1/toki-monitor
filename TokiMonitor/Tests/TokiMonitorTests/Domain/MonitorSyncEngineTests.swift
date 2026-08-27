import Testing
import Foundation
@testable import TokiMonitor

// MARK: - A server that behaves like the real one
//
// Same compare-and-swap rule as `upsert_monitor_setting`: a write carrying
// `if_version` lands only if the stored version still matches, and `0` means
// "expect no entry". Everything these tests are about lives in that rule, so a
// fake that skipped it would prove nothing.

final class FakeMonitorServer: @unchecked Sendable, MonitorSettingsTransport {
    private let lock = NSLock()
    private var storage: [String: MonitorSettingEntry] = [:]

    /// When set, every call fails this way — server down, token expired, no network.
    var failure: MonitorSyncError?
    /// When set, only writes fail. Reads still work.
    var writeFailure: MonitorSyncError?

    /// Writes that landed.
    private(set) var writeCount = 0
    /// Writes that were ATTEMPTED, refused ones included. The difference is the
    /// point when the server is asking the client to slow down.
    private(set) var writeAttempts = 0
    private(set) var deleteCount = 0

    /// Runs at the start of a write, so a test can let another machine's write
    /// land in the window between reading the index and writing. That window is
    /// exactly what the compare-and-swap exists to close.
    var beforeWrite: (@Sendable () -> Void)?

    // MARK: Seeding and inspection

    func seed(_ key: String, _ value: String, version: Int64 = 1) {
        lock.withLock {
            storage[key] = MonitorSettingEntry(key: key, value: value,
                                               version: version, updatedAt: 1_750_000_000)
        }
    }

    func value(for key: String) -> String? { lock.withLock { storage[key]?.value } }
    func version(for key: String) -> Int64? { lock.withLock { storage[key]?.version } }
    var keys: Set<String> { lock.withLock { Set(storage.keys) } }

    // MARK: Transport

    func index() throws -> MonitorSettingsIndex {
        if let failure { throw failure }
        return lock.withLock {
            MonitorSettingsIndex(
                entries: storage.values.map {
                    MonitorSettingMeta(key: $0.key, version: $0.version,
                                       updatedAt: $0.updatedAt, sizeBytes: $0.value.utf8.count)
                }.sorted { $0.key < $1.key },
                quota: .unknown
            )
        }
    }

    func list() throws -> [MonitorSettingEntry] {
        if let failure { throw failure }
        return lock.withLock { storage.values.sorted { $0.key < $1.key } }
    }

    func get(key: String) throws -> MonitorSettingEntry {
        if let failure { throw failure }
        return try lock.withLock {
            guard let entry = storage[key] else { throw MonitorSyncError.notFound(key: key) }
            return entry
        }
    }

    @discardableResult
    func put(key: String, value: String, ifVersion: Int64?) throws -> MonitorSettingWrite {
        lock.withLock { writeAttempts += 1 }
        if let failure { throw failure }
        if let writeFailure { throw writeFailure }
        beforeWrite?()
        return try lock.withLock {
            writeCount += 1
            let existing = storage[key]
            if let ifVersion {
                let current = existing?.version ?? 0
                guard current == ifVersion else {
                    throw MonitorSyncError.conflict(
                        key: key, currentVersion: current,
                        currentUpdatedAt: existing?.updatedAt ?? 0
                    )
                }
            }
            let next = (existing?.version ?? 0) + 1
            storage[key] = MonitorSettingEntry(key: key, value: value,
                                               version: next, updatedAt: 1_750_000_100)
            return MonitorSettingWrite(key: key, version: next, updatedAt: 1_750_000_100,
                                       previousVersion: existing?.version,
                                       created: existing == nil)
        }
    }

    func delete(key: String) throws {
        if let failure { throw failure }
        if let writeFailure { throw writeFailure }
        try lock.withLock {
            deleteCount += 1
            guard storage.removeValue(forKey: key) != nil else {
                throw MonitorSyncError.notFound(key: key)
            }
        }
    }
}

/// Fires once. A race happens once; a hook that fired on every write would
/// make the retry race too, and the test would prove something else.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func fire() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

// MARK: -

/// The monitor settings channel, and the one promise it makes: a sync never
/// replaces local state the user has not seen.
///
/// Dashboards are typed by hand and exist nowhere else. There is no log to
/// replay them from and no provider to re-fetch them from, so a sync that
/// resolves a disagreement by picking a side is a sync that silently destroys
/// an afternoon of somebody's work. Every branch below is a place where that
/// could happen.
@Suite("Monitor settings sync never overwrites unseen work")
@MainActor
struct MonitorSyncEngineTests {

    // MARK: Fixtures

    private func dashboard(_ title: String, uid: String) -> DashboardConfig {
        var config = DashboardConfig()
        config.title = title
        config.uid = uid
        return config
    }

    private func makeEngine(
        _ server: FakeMonitorServer, _ defaults: UserDefaults, seed: [DashboardConfig]
    ) -> (engine: MonitorSyncEngine, store: DashboardConfigStore) {
        let store = DashboardConfigStore(defaults: defaults)
        store.saveDashboardList(seed)
        let engine = MonitorSyncEngine(transport: server, store: store, defaults: defaults)
        engine.isEnabled = true
        return (engine, store)
    }

    private func exported(_ config: DashboardConfig) -> String {
        try! DashboardExchange.exportString(config)
    }

    // MARK: - Off unless asked for

    @Test("nothing happens until the user turns it on")
    func optInIsReal() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let store = DashboardConfigStore(defaults: defaults)
        store.saveDashboardList([dashboard("Mine", uid: "aaaa1111")])
        let engine = MonitorSyncEngine(transport: server, store: store, defaults: defaults)

        #expect(engine.isEnabled == false, "the channel is off in a fresh installation")
        let outcome = await engine.sync()
        #expect(outcome == MonitorSyncOutcome())
        #expect(server.keys.isEmpty, "an opt-in channel must not upload anything before the opt-in")
        #expect(server.writeCount == 0)
    }

    // MARK: - The first sync on a machine that already has dashboards

    @Test("a first sync adds what is missing and asks about what disagrees")
    func firstSyncNeverOverwrites() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()

        let mine = dashboard("My Costs", uid: "aaaa1111")
        let untouched = dashboard("Only Here", uid: "bbbb2222")
        let (engine, store) = makeEngine(server, defaults, seed: [mine, untouched])

        // The same uid exists on the server under a different title: the same
        // dashboard, edited on another Mac.
        var theirs = dashboard("My Costs (edited elsewhere)", uid: "aaaa1111")
        theirs.tags = ["from-the-other-mac"]
        server.seed("dashboard:aaaa1111", exported(theirs), version: 3)
        // And one that only exists there.
        let onlyThere = dashboard("Only There", uid: "cccc3333")
        server.seed("dashboard:cccc3333", exported(onlyThere), version: 1)

        let outcome = await engine.sync()

        // The disagreement is a question, not an action.
        #expect(outcome.conflicts.count == 1)
        let conflict = try! #require(outcome.conflicts.first)
        #expect(conflict.key == "dashboard:aaaa1111")
        #expect(conflict.kind == .divergent)
        #expect(conflict.local?.title == "My Costs")
        #expect(conflict.remote?.title == "My Costs (edited elsewhere)")

        let titles = store.loadDashboardList().map(\.title)
        #expect(titles.contains("My Costs"),
                "the local copy of a disputed dashboard must still be exactly as the user left it")
        #expect(!titles.contains("My Costs (edited elsewhere)"),
                "the server's copy must NOT have been applied over it")

        // What only exists on one side needs no decision.
        #expect(titles.contains("Only There"), "a dashboard that is only on the server is added")
        #expect(outcome.pulled.contains("dashboard:cccc3333"))
        #expect(server.value(for: "dashboard:bbbb2222") != nil,
                "a dashboard that is only here is uploaded")
        #expect(outcome.pushed.contains("dashboard:bbbb2222"))

        // And the disputed key on the server is untouched.
        #expect(server.version(for: "dashboard:aaaa1111") == 3)
        #expect(server.value(for: "dashboard:aaaa1111") == exported(theirs))
    }

    @Test("two sides that already agree need no decision and no upload")
    func identicalSidesConverge() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let same = dashboard("Same", uid: "aaaa1111")
        let (engine, _) = makeEngine(server, defaults, seed: [same])
        server.seed("dashboard:aaaa1111", exported(same), version: 5)

        let outcome = await engine.sync()

        #expect(outcome.conflicts.isEmpty)
        #expect(!outcome.pushed.contains("dashboard:aaaa1111"))
        #expect(!outcome.pulled.contains("dashboard:aaaa1111"))
        #expect(server.version(for: "dashboard:aaaa1111") == 5, "an unchanged dashboard is not rewritten")
    }

    @Test("a second run with nothing changed writes nothing")
    func steadyStateIsQuiet() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])

        _ = await engine.sync()
        let writesAfterFirst = server.writeCount
        let second = await engine.sync()

        #expect(second.didChangeAnything == false)
        #expect(server.writeCount == writesAfterFirst,
                "the ledger's hash is what stops every sync re-uploading every dashboard")
    }

    // MARK: - Losing a write race

    @Test("a 409 becomes a question, and the other machine's write stands")
    func writeRaceIsNeverResolvedByRetrying() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        var mine = dashboard("Mine", uid: "aaaa1111")
        let (engine, store) = makeEngine(server, defaults, seed: [mine])

        // Agree on a starting point.
        _ = await engine.sync()
        #expect(server.version(for: "dashboard:aaaa1111") == 1)

        // Another machine writes.
        let theirs = dashboard("Theirs", uid: "aaaa1111")
        server.seed("dashboard:aaaa1111", exported(theirs), version: 9)

        // This machine edits too, then syncs.
        mine.title = "Mine, edited"
        store.updateDashboardInList(mine)
        let outcome = await engine.sync()

        let conflict = try! #require(outcome.conflicts.first)
        #expect(conflict.kind == .divergent)
        #expect(conflict.local?.title == "Mine, edited")
        #expect(conflict.remote?.title == "Theirs")
        #expect(server.value(for: "dashboard:aaaa1111") == exported(theirs),
                "nothing may be written over the other machine's copy without a decision")
        #expect(store.loadDashboardList().first(where: { $0.uid == "aaaa1111" })?.title == "Mine, edited",
                "and nothing may be written over this machine's copy either")
    }

    @Test("a race that opens between the plan and the write is still a question")
    func serverSideConflictBecomesAWriteRace() async {
        // The narrow window: the index said version 1, this machine decided to
        // write, and another machine wrote before the request landed. The
        // compare-and-swap is what turns that into a 409 instead of a silent
        // overwrite, so the race is run for real here rather than faked with a
        // canned error.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        var mine = dashboard("A", uid: "aaaa1111")
        let (engine, store) = makeEngine(server, defaults, seed: [mine])
        _ = await engine.sync()

        mine.title = "A, edited here"
        store.updateDashboardInList(mine)

        let theirs = exported(dashboard("Theirs", uid: "aaaa1111"))
        let raced = OneShot()
        server.beforeWrite = { [weak server] in
            guard raced.fire() else { return }
            server?.seed("dashboard:aaaa1111", theirs, version: 4)
        }

        let outcome = await engine.sync()
        server.beforeWrite = nil

        let conflict = try! #require(outcome.conflicts.first { $0.key == "dashboard:aaaa1111" })
        #expect(conflict.kind == .writeRace(serverVersion: 4))
        #expect(conflict.remote?.title == "Theirs",
                "the user is shown what they would be overwriting, not just told they lost")
        #expect(server.value(for: "dashboard:aaaa1111") == theirs,
                "the write that lost the race did not land")
        #expect(store.loadDashboardList().first { $0.uid == "aaaa1111" }?.title == "A, edited here",
                "and the edit that lost it is still here")
    }

    // MARK: - Resolving

    @Test("keeping this machine's copy replaces the server's, and only then")
    func keepLocal() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let mine = dashboard("Mine", uid: "aaaa1111")
        let (engine, _) = makeEngine(server, defaults, seed: [mine])
        server.seed("dashboard:aaaa1111", exported(dashboard("Theirs", uid: "aaaa1111")), version: 3)

        let conflict = try! #require(await engine.sync().conflicts.first)
        let result = await engine.resolve(conflict, with: .keepLocal)

        #expect(result.pushed == ["dashboard:aaaa1111"])
        #expect(server.value(for: "dashboard:aaaa1111") == exported(mine))
        #expect(server.version(for: "dashboard:aaaa1111") == 4)
        // And the decision sticks: the next run has nothing to say.
        let after = await engine.sync()
        #expect(after.conflicts.isEmpty)
        #expect(after.didChangeAnything == false)
    }

    @Test("taking the server's copy replaces this machine's, and only then")
    func takeRemote() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(server, defaults, seed: [dashboard("Mine", uid: "aaaa1111")])
        let theirs = dashboard("Theirs", uid: "aaaa1111")
        server.seed("dashboard:aaaa1111", exported(theirs), version: 3)

        let conflict = try! #require(await engine.sync().conflicts.first)
        let result = await engine.resolve(conflict, with: .takeRemote)

        #expect(result.pulled == ["dashboard:aaaa1111"])
        #expect(store.loadDashboardList().first(where: { $0.uid == "aaaa1111" })?.title == "Theirs")
        let after = await engine.sync()
        #expect(after.conflicts.isEmpty)
        #expect(after.didChangeAnything == false)
    }

    @Test("keeping both loses neither")
    func keepBoth() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let mine = dashboard("Report", uid: "aaaa1111")
        let (engine, store) = makeEngine(server, defaults, seed: [mine])
        server.seed("dashboard:aaaa1111",
                    exported(dashboard("Report (theirs)", uid: "aaaa1111")), version: 3)

        let conflict = try! #require(await engine.sync().conflicts.first)
        #expect(conflict.canKeepBoth)
        _ = await engine.resolve(conflict, with: .keepBoth)

        let list = store.loadDashboardList()
        #expect(list.contains { $0.title == "Report" }, "this machine's copy stays")
        #expect(list.contains { $0.title.contains("theirs") }, "and the server's copy arrives beside it")
        // The two are separate documents, not one document twice.
        let uids = Set(list.map(\.uid))
        #expect(uids.count == list.count)
        #expect(server.value(for: "dashboard:aaaa1111") == exported(mine))
    }

    @Test("the preferences snapshot cannot be kept twice")
    func prefsCannotKeepBoth() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        defaults.set("rabbit", forKey: "animationThemeId")
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])
        server.seed(MonitorSyncKey.preferences,
                    #"{"schema":1,"values":{"animationThemeId":{"t":"s","v":"turtle"}}}"#, version: 2)

        let conflict = try! #require(await engine.sync().conflicts.first {
            $0.key == MonitorSyncKey.preferences
        })
        #expect(conflict.canKeepBoth == false,
                "there is one preferences snapshot; keeping two would be keeping neither")
    }

    // MARK: - Deletion

    @Test("a deletion elsewhere does not delete anything here")
    func remoteDeletionAsks() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(server, defaults, seed: [dashboard("Mine", uid: "aaaa1111")])
        _ = await engine.sync()

        try! server.delete(key: "dashboard:aaaa1111")
        let outcome = await engine.sync()

        let conflict = try! #require(outcome.conflicts.first { $0.key == "dashboard:aaaa1111" })
        #expect(conflict.kind == .deletedOnServer)
        #expect(store.loadDashboardList().contains { $0.uid == "aaaa1111" },
                "another machine's delete must never silently remove a dashboard from this one")

        // Following it is a choice the user makes.
        _ = await engine.resolve(conflict, with: .deleteLocal)
        #expect(!store.loadDashboardList().contains { $0.uid == "aaaa1111" })
    }

    @Test("keeping a dashboard the other machine deleted puts it back")
    func remoteDeletionCanBeRefused() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let mine = dashboard("Mine", uid: "aaaa1111")
        let (engine, _) = makeEngine(server, defaults, seed: [mine])
        _ = await engine.sync()
        try! server.delete(key: "dashboard:aaaa1111")

        let conflict = try! #require(await engine.sync().conflicts.first)
        _ = await engine.resolve(conflict, with: .keepLocal)
        #expect(server.value(for: "dashboard:aaaa1111") == exported(mine))
    }

    @Test("deleting a dashboard here removes it there, so it does not come back")
    func localDeletionPropagates() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(
            server, defaults, seed: [dashboard("A", uid: "aaaa1111"), dashboard("B", uid: "bbbb2222")]
        )
        _ = await engine.sync()

        store.deleteDashboard(uid: "bbbb2222")
        let outcome = await engine.sync()

        #expect(outcome.deletedOnServer == ["dashboard:bbbb2222"])
        #expect(server.value(for: "dashboard:bbbb2222") == nil)

        // The next run must not resurrect it.
        let after = await engine.sync()
        #expect(!store.loadDashboardList().contains { $0.uid == "bbbb2222" })
        #expect(after.didChangeAnything == false)
    }

    // MARK: - Failure

    @Test("a server that is not there costs nothing")
    func totalFailureLosesNothing() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let seed = [dashboard("A", uid: "aaaa1111"), dashboard("B", uid: "bbbb2222")]
        let (engine, store) = makeEngine(server, defaults, seed: seed)
        let before = store.loadDashboardList().map(\.title)

        server.failure = .networkError("The Internet connection appears to be offline.")
        let outcome = await engine.sync()

        #expect(outcome.failure != nil)
        #expect(outcome.didChangeAnything == false)
        #expect(store.loadDashboardList().map(\.title) == before)
        #expect(engine.loadLedger().entries.isEmpty,
                "a run that never started must not record an agreement it did not reach")
    }

    @Test("an expired token is reported, not worked around")
    func expiredTokenIsReported() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])
        server.failure = .tokenExpired

        let outcome = await engine.sync()
        #expect(outcome.failure == MonitorSyncError.tokenExpired.errorDescription)
        #expect(store.loadDashboardList().count == 1)
    }

    @Test("a write that fails leaves the key unsynced, and the next run retries it")
    func failedWriteIsRetried() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])

        server.writeFailure = .quotaExceeded(reason: "monitor settings quota exceeded")
        let first = await engine.sync()
        #expect(first.pushed.isEmpty)
        #expect(!first.problems.isEmpty)
        #expect(store.loadDashboardList().count == 1, "a failed upload changes nothing here")
        #expect(engine.loadLedger()["dashboard:aaaa1111"] == nil)

        server.writeFailure = nil
        let second = await engine.sync()
        #expect(second.pushed.contains("dashboard:aaaa1111"))
    }

    @Test("a dashboard that will not decode costs itself and nothing else")
    func oneBadPayloadDoesNotStopThePull() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, store) = makeEngine(server, defaults, seed: [dashboard("Mine", uid: "aaaa1111")])

        server.seed("dashboard:cccc3333", "{ this is not json", version: 1)
        server.seed("dashboard:dddd4444", exported(dashboard("Good", uid: "dddd4444")), version: 1)

        let outcome = await engine.sync()

        #expect(outcome.problems.contains { $0.key == "dashboard:cccc3333" })
        #expect(outcome.pulled.contains("dashboard:dddd4444"))
        let titles = store.loadDashboardList().map(\.title)
        #expect(titles.contains("Mine"), "what was already here survives a bad payload")
        #expect(titles.contains("Good"), "and so does the rest of the pull")
    }

    @Test("an agreement is recorded only for a pull that actually landed")
    func ledgerFollowsTheWrite() async {
        // The store's own contract: a save that cannot happen leaves the
        // previous state intact and says so (계약 C6). The engine records an
        // agreement only on the back of a save that reported success, so a
        // failed one is simply retried rather than forgotten.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("Mine", uid: "aaaa1111")])
        server.seed("dashboard:dddd4444", exported(dashboard("Good", uid: "dddd4444")), version: 1)

        _ = await engine.sync()
        #expect(engine.loadLedger()["dashboard:dddd4444"]?.version == 1,
                "a pull that DID land is recorded, so the next run does not fetch it again")
    }

    // MARK: - Preferences

    @Test("a machine with nothing configured takes the server's settings instead of disputing them")
    func freshMachineAdoptsPreferences() async {
        // Its local preferences are factory defaults, not choices. Raising a
        // conflict between "the server" and "nobody has set anything here yet"
        // is a decision with no content in it.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])
        server.seed(MonitorSyncKey.preferences,
                    #"{"schema":1,"values":{"animationThemeId":{"t":"s","v":"turtle"}}}"#, version: 2)

        let outcome = await engine.sync()

        #expect(outcome.conflicts.isEmpty)
        #expect(outcome.pulled.contains(MonitorSyncKey.preferences))
        #expect(defaults.string(forKey: "animationThemeId") == "turtle")
    }

    @Test("preferences set here are never read as a deletion")
    func preferencesAreNeverDeletedRemotely() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        defaults.set("rabbit", forKey: "animationThemeId")
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("A", uid: "aaaa1111")])
        _ = await engine.sync()
        #expect(server.value(for: MonitorSyncKey.preferences) != nil)

        // Every preference goes away on this machine — a reset, a new profile.
        // That is an empty snapshot, not an instruction to wipe the settings on
        // the user's other Macs.
        defaults.removeObject(forKey: "animationThemeId")
        let outcome = await engine.sync()

        #expect(!outcome.deletedOnServer.contains(MonitorSyncKey.preferences))
        #expect(server.value(for: MonitorSyncKey.preferences) != nil)
    }

    @Test("a pulled preference reaches the settings object, not just the defaults")
    func pulledPreferencesReachTheLiveSettings() async {
        // Without this, the running `AppSettings` still holds what it read at
        // launch and its next debounced save writes it straight back over what
        // was just pulled: the sync appears to work and then undoes itself.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let store = DashboardConfigStore(defaults: defaults)
        store.saveDashboardList([dashboard("A", uid: "aaaa1111")])
        let engine = MonitorSyncEngine(transport: server, store: store, defaults: defaults)
        engine.isEnabled = true

        let settings = AppSettings(defaults: defaults)
        #expect(settings.animationThemeId == "rabbit")

        server.seed(MonitorSyncKey.preferences,
                    #"{"schema":1,"values":{"animationThemeId":{"t":"s","v":"turtle"},"showRateText":{"t":"b","v":true}}}"#,
                    version: 1)

        let controller = MonitorSyncController(engine: engine, settings: { settings })
        await controller.syncNow()

        #expect(settings.animationThemeId == "turtle")
        #expect(settings.showRateText == true)
    }

    // MARK: - Backing off

    @Test("being told to slow down stops the run's writes instead of repeating them")
    func rateLimitPausesTheRun() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let seed = (0..<5).map { dashboard("D\($0)", uid: "dddd000\($0)") }
        let (engine, store) = makeEngine(server, defaults, seed: seed)

        server.writeFailure = .rateLimited(retryAfter: 30)
        let outcome = await engine.sync()

        #expect(server.writeAttempts == 1,
                "one refusal is enough; the budget is per minute and the rest would all fail")
        #expect(outcome.pushed.isEmpty)
        #expect(store.loadDashboardList().count == seed.count, "and nothing here changed")

        // The next run, after the window, pushes everything.
        server.writeFailure = nil
        let after = await engine.sync()
        #expect(after.pushed.count >= seed.count)
    }

    // MARK: - What travels

    @Test("a dashboard travels in the export shape, not a second serialisation")
    func payloadIsTheExportShape() async {
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let config = dashboard("Costs", uid: "aaaa1111")
        let (engine, _) = makeEngine(server, defaults, seed: [config])

        _ = await engine.sync()

        #expect(server.value(for: "dashboard:aaaa1111") == exported(config),
                "the export format is complete and lossless; a private wire format here would be a second idea of what a dashboard is, free to drift")
    }

    @Test("keys this build has no name for survive the round trip")
    func unknownKeysSurvive() async {
        // The store learned to preserve them; a sync round trip must not be the
        // thing that finally drops them.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()

        var object = try! JSONSerialization.jsonObject(
            with: try! JSONEncoder().encode(dashboard("Has extras", uid: "aaaa1111"))
        ) as! [String: Any]
        object["somethingANewerBuildWrote"] = ["nested": [1, 2, 3]]
        let withExtras = try! JSONDecoder().decode(
            DashboardConfig.self,
            from: try! JSONSerialization.data(withJSONObject: object)
        )

        let (engine, store) = makeEngine(server, defaults, seed: [withExtras])
        _ = await engine.sync()

        let uploaded = try! #require(server.value(for: "dashboard:aaaa1111"))
        #expect(uploaded.contains("somethingANewerBuildWrote"),
                "the upload must carry the key this build cannot name")

        // And it comes back intact on the other machine.
        let otherDefaults = ScratchDefaults()
        let otherStore = DashboardConfigStore(defaults: otherDefaults)
        otherStore.saveDashboardList([dashboard("Local", uid: "bbbb2222")])
        let otherEngine = MonitorSyncEngine(transport: server, store: otherStore,
                                            defaults: otherDefaults)
        otherEngine.isEnabled = true
        _ = await otherEngine.sync()

        let arrived = try! #require(otherStore.loadDashboardList().first { $0.uid == "aaaa1111" })
        #expect(arrived.unknownFields["somethingANewerBuildWrote"] != nil)
        _ = store
    }

    @Test("a document from a newer schema goes up as its own bytes")
    func futureSchemaKeepsItsBytes() async {
        // Re-encoding it would let this build decide what a future schema looks
        // like — writing back only the fields it happens to have (계약 C2).
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()

        var object = try! JSONSerialization.jsonObject(
            with: try! JSONEncoder().encode(dashboard("From the future", uid: "ffff9999"))
        ) as! [String: Any]
        object["schemaVersion"] = 99
        object["aFieldFromTheFuture"] = "kept"
        let bytes = try! JSONSerialization.data(withJSONObject: object)
        let future = try! JSONDecoder().decode(DashboardConfig.self, from: bytes)
        #expect(future.isReadOnlyForThisBuild)
        DashboardConfigStore.rememberOriginal(future, bytes: bytes)

        let (engine, _) = makeEngine(server, defaults, seed: [future])
        _ = await engine.sync()

        let uploaded = try! #require(server.value(for: "dashboard:ffff9999"))
        #expect(uploaded.contains("aFieldFromTheFuture"))

        // Key ORDER is not preserved — a JSON object has none, and the store
        // round-trips through `JSONSerialization` on the way to disk. What must
        // be preserved is every key and every value, which is what a re-encode
        // through this build's `Codable` would not manage.
        let sent = try! JSONSerialization.jsonObject(with: Data(uploaded.utf8)) as! NSDictionary
        #expect(sent == (try! JSONSerialization.jsonObject(with: bytes) as! NSDictionary),
                "not one field of a future-schema document may be dropped or normalised")
        #expect(sent["schemaVersion"] as? Int == 99)
    }

    @Test("no query results, usage or cost figures leave the machine")
    func onlyConfigurationTravels() async {
        // 계약 C3 lives in the export path. This is the check that syncing did
        // not quietly acquire a second path around it.
        let server = FakeMonitorServer()
        let defaults = ScratchDefaults()
        let (engine, _) = makeEngine(server, defaults, seed: [dashboard("Costs", uid: "aaaa1111")])
        _ = await engine.sync()

        let uploaded = try! #require(server.value(for: "dashboard:aaaa1111"))
        let document = try! JSONSerialization.jsonObject(
            with: Data(uploaded.utf8)) as! [String: Any]
        for forbidden in ["results", "series", "points", "frames", "usage", "cost", "totalTokens"] {
            #expect(!document.keys.contains(forbidden),
                    "a dashboard on the wire is configuration; '\(forbidden)' is data")
        }
    }
}
