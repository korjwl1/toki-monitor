import Foundation
import Testing
@testable import TokiMonitor

/// Guard tests for the thing every store persistence test depends on.
///
/// `ScratchDefaults` subclasses `UserDefaults`, so any entry point it forgets
/// to override falls through to the real search list — and a *write* that
/// falls through lands in `com.toki.monitor`, the live domain holding the
/// user's dashboards. That is the accident these tests exist to make loud:
/// if the fake ever stops holding a value, the write went somewhere else.
@Suite("Scratch defaults never reach a real domain")
struct ScratchDefaultsTests {

    /// A key no production code writes, so a leak through to the app domain is
    /// visible rather than confused with a real setting.
    private let key = "scratchDefaultsProbe.\(UUID().uuidString)"

    @Test("every set overload is held in memory and read back")
    func setOverloadsRoundTrip() {
        ScratchDefaults.with { d in
            d.set(Data("bytes".utf8), forKey: key)
            #expect(d.data(forKey: key) == Data("bytes".utf8))

            d.set(true, forKey: key)
            #expect(d.bool(forKey: key) == true)

            d.set(7, forKey: key)
            #expect(d.integer(forKey: key) == 7)

            d.set(1.5, forKey: key)
            #expect(d.double(forKey: key) == 1.5)

            d.set(Float(2.5), forKey: key)
            #expect(d.float(forKey: key) == 2.5)

            d.set(URL(string: "https://example.invalid")!, forKey: key)
            #expect(d.url(forKey: key)?.absoluteString == "https://example.invalid")

            d.set("text" as Any?, forKey: key)
            #expect(d.string(forKey: key) == "text")
        }
    }

    @Test("nothing written to a scratch defaults appears in the real domain")
    func writesDoNotEscape() {
        ScratchDefaults.with { d in
            d.set(Data("bytes".utf8), forKey: key)
            d.set(true, forKey: "\(key).bool")
            d.set(42, forKey: "\(key).int")
        }

        // Read-only checks against `.standard` — the one direction that is safe.
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(UserDefaults.standard.object(forKey: "\(key).bool") == nil)
        #expect(UserDefaults.standard.object(forKey: "\(key).int") == nil)
    }

    @Test("two scratch defaults do not see each other")
    func instancesAreIsolated() {
        ScratchDefaults.with { a in
            a.set(Data("a".utf8), forKey: key)
            ScratchDefaults.with { b in
                #expect(b.data(forKey: key) == nil)
                b.set(Data("b".utf8), forKey: key)
            }
            #expect(a.data(forKey: key) == Data("a".utf8))
        }
    }

    @Test("removing a key and setting nil both clear it")
    func removal() {
        ScratchDefaults.with { d in
            d.set(Data("x".utf8), forKey: key)
            d.removeObject(forKey: key)
            #expect(d.data(forKey: key) == nil)

            d.set(Data("x".utf8), forKey: key)
            d.set(nil, forKey: key)
            #expect(d.data(forKey: key) == nil)
        }
    }

    @Test("a scratch defaults leaves no plist behind, because it never made one")
    func noPreferencesFile() {
        // The pile of `toki.monitor.tests.<uuid>.plist` files in
        // ~/Library/Preferences is what a suite-backed scratch defaults costs.
        // This one has no suite name to leave a file under.
        let before = leakedScratchPlists()
        ScratchDefaults.with { d in d.set(Data("x".utf8), forKey: key) }
        #expect(leakedScratchPlists() == before)
    }

    private func leakedScratchPlists() -> Int {
        let dir = ("~/Library/Preferences" as NSString).expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasPrefix("toki.monitor.tests.") }.count
    }
}
