import Testing
import Foundation
@testable import TokiMonitor

// What a panel says to a screen reader, per state.
//
// These assert on the SENTENCE, not on the presence of an `.accessibilityLabel`
// modifier. A label that exists and reads "chart" passes the second kind of
// test and tells a VoiceOver reader nothing, which is the failure mode this
// suite is here to catch.

// `L.tr` reads the app language through `MainActor.assumeIsolated`, so every
// string these assert on has to be produced on the main actor.
@Suite("Panel accessibility announcement")
@MainActor
struct PanelAccessibilityTests {

    private func say(_ state: PanelState?, value: String? = nil) -> String {
        PanelAccessibility.announcement(title: "Total tokens",
                                        typeName: "Time Series",
                                        state: state, value: value)
    }

    @Test("every state produces a different sentence")
    func statesAreDistinguishable() {
        let sentences = [
            say(.idle),
            say(.loading(hasPrevious: false)),
            say(.loading(hasPrevious: true), value: "2 series, opus, latest 24K"),
            say(.loaded, value: "2 series, opus, latest 24K"),
            say(.empty(.noDataInRange)),
            say(.empty(.allSeriesHidden)),
            say(.failed(reason: "connection refused (127.0.0.1:9494)")),
        ]
        #expect(Set(sentences).count == sentences.count,
                "two states read the same to a screen reader: \(sentences)")
    }

    @Test("identity comes first, so a reader can navigate on it")
    func identityLeads() {
        for state in [PanelState.idle, .loaded, .empty(.noDataInRange),
                      .failed(reason: "x"), .loading(hasPrevious: false)] {
            #expect(say(state, value: "1.2M").hasPrefix("Total tokens, Time Series"),
                    "\(state) does not lead with the panel's identity")
        }
    }

    @Test("a failed panel says it failed, and says why")
    func failureIsSpoken() {
        let spoken = say(.failed(reason: "connection refused (127.0.0.1:9494)"))
        #expect(spoken.contains(PanelState.failed(reason: "x").title),
                "the failed state must name itself, not merely fall silent")
        #expect(spoken.contains("connection refused (127.0.0.1:9494)"),
                "the reason must be spoken verbatim, not summarised as 'error'")
    }

    @Test("an empty panel is not silent, and says which kind of empty")
    func emptyIsSpoken() {
        let noData = say(.empty(.noDataInRange))
        let hidden = say(.empty(.allSeriesHidden))
        #expect(noData != hidden)
        // Each carries its own remedy — widen the range vs. turn a series on.
        #expect(noData.contains(PanelState.empty(.noDataInRange).detail ?? "!"))
        #expect(hidden.contains(PanelState.empty(.allSeriesHidden).detail ?? "!"))
    }

    @Test("a loaded panel speaks its value and does not say the word 'Result'")
    func loadedSpeaksValue() {
        let spoken = say(.loaded, value: "2 series, opus, latest 24K")
        #expect(spoken.contains("2 series, opus, latest 24K"))
        #expect(!spoken.contains(PanelState.loaded.title),
                "'\(PanelState.loaded.title)' on every panel is verbosity, not information")
    }

    @Test("a held-over result says it is stale AND still reads the numbers")
    func staleIsSpoken() {
        let spoken = say(.loading(hasPrevious: true), value: "1.2M")
        #expect(spoken.contains(PanelState.loading(hasPrevious: true).title))
        #expect(spoken.contains("1.2M"),
                "the previous result is still on screen, so it is still what the panel says")
    }

    @Test("a panel with no query state is just a name and a kind")
    func statelessPanel() {
        let spoken = PanelAccessibility.announcement(title: "Costs", typeName: "Row",
                                                     state: nil, value: nil)
        #expect(spoken == "Costs, Row")
    }

    @Test("an empty value is dropped rather than spoken as a trailing full stop")
    func emptyValueDropped() {
        #expect(say(.loaded, value: "") == "Total tokens, Time Series")
    }

    @Test("the hint names only actions the panel actually has")
    func hintNamesRealActions() {
        #expect(PanelAccessibility.hint(canInspect: false, canEdit: false,
                                        canDelete: false) == nil)
        let readOnly = PanelAccessibility.hint(canInspect: true, canEdit: true,
                                               canDelete: false)
        #expect(readOnly?.contains(L.tr("삭제", "Delete")) == false,
                "a panel that cannot be deleted must not offer deleting")
    }
}
