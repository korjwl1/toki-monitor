import Testing
import Foundation
@testable import TokiMonitor

/// The preferences half of the settings channel.
///
/// `UserDefaults` holds five kinds of value and JSON can tell apart three of
/// them, so a snapshot that does not say what each value IS comes back with
/// `showRateText` as the number 1 and `velocityThreshold` as the integer 0.
/// Neither would look like a bug on the machine that sent it.
@Suite("The preferences snapshot says what each value is")
@MainActor
struct MonitorPrefsSnapshotTests {

    @Test("every kind of preference survives the round trip as itself")
    func typesSurvive() {
        let source = ScratchDefaults()
        source.set("turtle", forKey: "animationThemeId")
        source.set(true, forKey: "showRateText")
        source.set(false, forKey: "velocityAlertEnabled")
        source.set(0.75, forKey: "velocityThreshold")
        source.set(2.0, forKey: "historicalMultiplier")
        let widgets = Data("[{\"id\":\"anthropic\"}]".utf8)
        source.set(widgets, forKey: "widgetOrder")

        let payload = try! #require(MonitorPrefsSnapshot.capture(from: source))

        let target = ScratchDefaults()
        let applied = try! #require(MonitorPrefsSnapshot.apply(payload, to: target))
        #expect(applied.foreign.isEmpty)

        #expect(target.string(forKey: "animationThemeId") == "turtle")
        #expect(target.object(forKey: "showRateText") as? Bool == true)
        #expect(target.object(forKey: "velocityAlertEnabled") as? Bool == false)
        #expect(target.double(forKey: "velocityThreshold") == 0.75)
        #expect(target.double(forKey: "historicalMultiplier") == 2.0)
        #expect(target.data(forKey: "widgetOrder") == widgets)

        // A bool must not come back as a number, or the menu bar quietly
        // changes shape on the other Mac.
        let roundTripped = target.object(forKey: "showRateText")
        #expect(roundTripped is Bool)
        #expect(CFGetTypeID(roundTripped as CFTypeRef) == CFBooleanGetTypeID())
    }

    @Test("a snapshot touches only the preferences it carries")
    func unrelatedPreferencesAreLeftAlone() {
        let source = ScratchDefaults()
        source.set("turtle", forKey: "animationThemeId")
        let payload = try! #require(MonitorPrefsSnapshot.capture(from: source))

        let target = ScratchDefaults()
        target.set("rabbit", forKey: "animationThemeId")
        target.set(true, forKey: "usageAlert90Enabled")
        MonitorPrefsSnapshot.apply(payload, to: target)

        #expect(target.string(forKey: "animationThemeId") == "turtle")
        #expect(target.object(forKey: "usageAlert90Enabled") as? Bool == true,
                "a preference the snapshot says nothing about is not a preference to erase")
    }

    @Test("what belongs to this machine stays on this machine")
    func machineLocalPreferencesDoNotTravel() {
        let source = ScratchDefaults()
        source.set(true, forKey: "launchAtLogin")
        source.set(Data("dashboards".utf8), forKey: "dashboardList")
        source.set("aaaa1111", forKey: "activeDashboardUID")
        source.set(Data("{}".utf8), forKey: "usageAlertNotifiedResets")
        source.set(Data("[]".utf8), forKey: "datasourceInstances")
        source.set("turtle", forKey: "animationThemeId")

        let payload = try! #require(MonitorPrefsSnapshot.capture(from: source))
        let values = try! #require(MonitorPrefsSnapshot.decode(payload))

        #expect(values["animationThemeId"] != nil)
        for key in MonitorPrefsSnapshot.deliberatelyLocal.keys {
            #expect(values[key] == nil,
                    "'\(key)' is deliberately local: \(MonitorPrefsSnapshot.deliberatelyLocal[key]!)")
        }
    }

    @Test("a snapshot that will not read applies nothing at all")
    func garbageAppliesNothing() {
        let target = ScratchDefaults()
        target.set("rabbit", forKey: "animationThemeId")

        #expect(MonitorPrefsSnapshot.apply("not json", to: target) == nil)
        #expect(MonitorPrefsSnapshot.apply("{\"schema\":1}", to: target) == nil)
        #expect(target.string(forKey: "animationThemeId") == "rabbit",
                "an unreadable snapshot is not an empty snapshot; reading it as one erases settings")
    }

    @Test("a preference a newer build knows about is kept, not written and not dropped")
    func foreignPreferencesSurviveTheRoundTrip() {
        // The older build has no field for it. Writing it into preferences
        // blind would put an unvalidated value where this build may later read
        // a different type; dropping it would mean opening the old build once
        // deletes the setting from the new one.
        let newer = #"""
            {"schema":1,"values":{
              "animationThemeId":{"t":"s","v":"turtle"},
              "aPreferenceFromLater":{"t":"s","v":"kept"}
            }}
            """#

        let machine = ScratchDefaults()
        let applied = try! #require(MonitorPrefsSnapshot.apply(newer, to: machine))
        #expect(applied.foreign == ["aPreferenceFromLater"])
        #expect(machine.object(forKey: "aPreferenceFromLater") == nil,
                "an unrecognised preference is not written into the preference domain")
        #expect(machine.string(forKey: "animationThemeId") == "turtle")

        // And the next push from this machine still carries it.
        let pushed = try! #require(MonitorPrefsSnapshot.capture(from: machine))
        let values = try! #require(MonitorPrefsSnapshot.decode(pushed))
        #expect(values["aPreferenceFromLater"] != nil,
                "a round trip through the older build must not be what deletes it")
    }

    @Test("applying a snapshot reports what it changed")
    func applicationReportsItsChanges() {
        let source = ScratchDefaults()
        source.set("turtle", forKey: "animationThemeId")
        source.set(true, forKey: "showRateText")
        let payload = try! #require(MonitorPrefsSnapshot.capture(from: source))

        let target = ScratchDefaults()
        target.set("rabbit", forKey: "animationThemeId")
        target.set(true, forKey: "showRateText")

        let applied = try! #require(MonitorPrefsSnapshot.apply(payload, to: target))
        #expect(applied.changing == ["animationThemeId"])
        #expect(applied.isNoOp == false)

        // Applying the same snapshot twice changes nothing the second time.
        let again = try! #require(MonitorPrefsSnapshot.apply(payload, to: target))
        #expect(again.isNoOp)
    }
}
