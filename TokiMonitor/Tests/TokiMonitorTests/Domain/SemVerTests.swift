import Testing
@testable import TokiMonitor

@Suite("SemVer")
struct SemVerTests {

    @Test("newer stable versions are upgrades")
    func newerStable() {
        #expect(SemVer.isNewerStable(latest: "2.1.0", current: "2.0.0"))
        #expect(SemVer.isNewerStable(latest: "v2.1.0", current: "2.0.9"))
        #expect(SemVer.isNewerStable(latest: "2.0.1", current: "2.0.0"))
        #expect(SemVer.isNewerStable(latest: "3.0.0", current: "2.9.9"))
    }

    @Test("equal or older is never an upgrade (downgrade protection)")
    func notNewer() {
        #expect(!SemVer.isNewerStable(latest: "2.0.0", current: "2.0.0"))
        #expect(!SemVer.isNewerStable(latest: "1.9.9", current: "2.0.0"))
        #expect(!SemVer.isNewerStable(latest: "1.0.0", current: "2.5.1"))
    }

    @Test("pre-release latest is never offered as an update")
    func prereleaseNotOffered() {
        #expect(!SemVer.isNewerStable(latest: "2.1.0-rc1", current: "2.0.0"))
        #expect(!SemVer.isNewerStable(latest: "3.0.0-beta", current: "2.0.0"))
        #expect(!SemVer.isNewerStable(latest: "2.1.0-dev2", current: "2.0.0"))
    }

    @Test("pre-release detection only matches after a hyphen")
    func prereleaseDetection() {
        #expect(SemVer.isPrerelease("1.2.3-rc1"))
        #expect(SemVer.isPrerelease("1.2.3-beta.2"))
        #expect(!SemVer.isPrerelease("1.2.3"))
        #expect(!SemVer.isPrerelease("1.2.3_1")) // brew revision, not pre-release
    }

    @Test("parsing strips build metadata and brew revision, never crashes")
    func parsingRobustness() {
        #expect(SemVer.isNewerStable(latest: "1.2.3+build7", current: "1.2.2"))
        #expect(!SemVer.isNewerStable(latest: "1.2.3_1", current: "1.2.3"))
        #expect(SemVer.core("not.a.version") == (0, 0, 0))
        #expect(SemVer.core("v10.20.30") == (10, 20, 30))
        #expect(SemVer.major("toki-style-2") == 0) // garbage → 0, no crash
        #expect(SemVer.major("2.1.0") == 2)
    }
}
