import Testing
@testable import TokiMonitor

@Suite("UpdateChecker.forcedResolution")
struct UpdateCheckerForcedResolutionTests {
    typealias Kind = UpdateChecker.CheckKind

    @Test("An installable update always wins")
    func updateWins() {
        #expect(UpdateChecker.forcedResolution(.update, .upToDate) == .update)
        #expect(UpdateChecker.forcedResolution(.upToDate, .update) == .update)
        #expect(UpdateChecker.forcedResolution(.update, .pending) == .update)
        #expect(UpdateChecker.forcedResolution(.failed, .update) == .update)
    }

    @Test("Pending Homebrew bump outranks failure and up-to-date")
    func pendingOverFailureAndUpToDate() {
        #expect(UpdateChecker.forcedResolution(.pending, .failed) == .pending)
        #expect(UpdateChecker.forcedResolution(.failed, .pending) == .pending)
        #expect(UpdateChecker.forcedResolution(.pending, .upToDate) == .pending)
    }

    @Test("Failure outranks up-to-date")
    func failureOverUpToDate() {
        #expect(UpdateChecker.forcedResolution(.failed, .upToDate) == .failed)
        #expect(UpdateChecker.forcedResolution(.upToDate, .failed) == .failed)
    }

    @Test("Both up to date → up to date")
    func bothUpToDate() {
        #expect(UpdateChecker.forcedResolution(.upToDate, .upToDate) == .upToDate)
    }
}
