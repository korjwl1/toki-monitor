import Testing
import Foundation
@testable import TokiMonitor

/// Alerts and playlists were removed from the product. The rules the user
/// wrote for them are a different question: nothing else on disk holds a copy,
/// there is no export, and the deletion happened during a launch the user did
/// not ask for. Constitution principle III makes that the expensive class of
/// change, so the keys are archived rather than dropped.
///
/// These exercise the archiving rule against a throwaway suite name; the real
/// `com.toki.monitor` domain is never touched.
@Suite("Data from a removed feature is retired, not destroyed")
struct RemovedFeatureArchiveTests {

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "toki.monitor.tests.archive.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Mirrors the production rule so the behaviour can be asserted without
    /// reaching into `.standard`.
    private func retire(_ keys: [String], in defaults: UserDefaults) {
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            let archiveKey = key + ".removedFeatureArchive"
            if defaults.object(forKey: archiveKey) == nil {
                defaults.set(value, forKey: archiveKey)
            }
            defaults.removeObject(forKey: key)
        }
    }

    @Test("the live key is cleared but the value is still recoverable")
    func valueSurvivesUnderTheArchiveKey() throws {
        let (d, name) = scratchDefaults()
        defer { d.removePersistentDomain(forName: name) }

        let rules = Data(#"[{"id":"a","threshold":80}]"#.utf8)
        d.set(rules, forKey: "dashboardAlertRules")

        retire(["dashboardAlertRules", "dashboardPlaylists"], in: d)

        #expect(d.object(forKey: "dashboardAlertRules") == nil, "the live key is cleared")
        #expect(d.data(forKey: "dashboardAlertRules.removedFeatureArchive") == rules,
                "the user's rules must still exist somewhere")
    }

    /// The purge runs on every launch. If it overwrote the archive, the second
    /// launch would destroy what the first one saved — the exact failure the
    /// archive exists to prevent, arriving one launch later.
    @Test("a second launch does not clobber the first launch's archive")
    func archiveIsWrittenOnlyOnce() throws {
        let (d, name) = scratchDefaults()
        defer { d.removePersistentDomain(forName: name) }

        let original = Data("original".utf8)
        d.set(original, forKey: "dashboardPlaylists")
        retire(["dashboardPlaylists"], in: d)

        // A later launch finds the key re-created (say, by an older build) and
        // retires it again.
        d.set(Data("later".utf8), forKey: "dashboardPlaylists")
        retire(["dashboardPlaylists"], in: d)

        #expect(d.data(forKey: "dashboardPlaylists.removedFeatureArchive") == original,
                "the first archive wins")
    }

    @Test("absent keys cost nothing and create no empty archive")
    func nothingToRetire() throws {
        let (d, name) = scratchDefaults()
        defer { d.removePersistentDomain(forName: name) }

        retire(["dashboardAlertRules", "dashboardPlaylists"], in: d)

        #expect(d.object(forKey: "dashboardAlertRules.removedFeatureArchive") == nil)
        #expect(d.object(forKey: "dashboardPlaylists.removedFeatureArchive") == nil)
    }
}
