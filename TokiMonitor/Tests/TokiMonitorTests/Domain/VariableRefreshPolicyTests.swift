import Testing
import Foundation
@testable import TokiMonitor

/// The three refresh policies, and whether they are actually three.
///
/// `VariableRefresh` has had three cases and one reader — a `switch` inside
/// `DashboardViewModel.refreshVariables` — since it was written, and nothing
/// stated what the difference between them was supposed to be. Two of them
/// coincide on every trigger except one, so "these two do the same thing" was
/// a live possibility that no test could rule out.
///
/// They do differ. This pins the table so that a later edit to the trigger
/// argument cannot quietly collapse two policies into one and leave the editor
/// offering a choice with no consequence (contract R1).
@Suite("Variable refresh policy")
struct VariableRefreshPolicyTests {

    private func variable(_ name: String,
                          _ refresh: DashboardVariable.VariableRefresh) -> DashboardVariable {
        DashboardVariable(name: name, type: .custom, refresh: refresh)
    }

    // MARK: - The table

    @Test("never reloads for no trigger")
    func neverIsNever() {
        #expect(!VariableResolver.shouldRefresh(.never, onTimeRangeChange: false))
        #expect(!VariableResolver.shouldRefresh(.never, onTimeRangeChange: true))
    }

    @Test("on dashboard load reloads at load and not on a time range change")
    func onLoadSkipsTimeRangeChange() {
        #expect(VariableResolver.shouldRefresh(.onDashboardLoad, onTimeRangeChange: false))
        #expect(!VariableResolver.shouldRefresh(.onDashboardLoad, onTimeRangeChange: true))
    }

    /// Reloading at load time as well is deliberate: a variable that has never
    /// loaded has no options, so a dashboard opened with one would show an
    /// empty picker until the reader happened to change the time range.
    @Test("on time range change reloads on both triggers")
    func onTimeRangeChangeCoversLoadToo() {
        #expect(VariableResolver.shouldRefresh(.onTimeRangeChanged, onTimeRangeChange: false))
        #expect(VariableResolver.shouldRefresh(.onTimeRangeChanged, onTimeRangeChange: true))
    }

    /// The claim the editor's picker makes: picking a different policy leads to
    /// a different outcome. Stated as "no two rows of the table are equal"
    /// rather than as three separate assertions, so adding a fourth policy that
    /// duplicates an existing one fails here.
    @Test("no two policies behave alike")
    func everyPolicyIsDistinct() {
        let policies: [DashboardVariable.VariableRefresh] =
            [.never, .onDashboardLoad, .onTimeRangeChanged]
        let rows = policies.map { policy in
            [VariableResolver.shouldRefresh(policy, onTimeRangeChange: false),
             VariableResolver.shouldRefresh(policy, onTimeRangeChange: true)]
        }
        for (i, a) in rows.enumerated() {
            for (j, b) in rows.enumerated() where i < j {
                #expect(a != b,
                        "\(policies[i]) and \(policies[j]) reload on exactly the same triggers")
            }
        }
    }

    // MARK: - Selecting from a dashboard's list

    @Test("a load refreshes everything except never")
    func loadSelection() {
        let list = [variable("a", .never),
                    variable("b", .onDashboardLoad),
                    variable("c", .onTimeRangeChanged)]
        let selected = VariableResolver.variablesToRefresh(list, onTimeRangeChange: false)
        #expect(selected.map(\.name) == ["b", "c"])
    }

    @Test("a time range change refreshes only the variables that asked for it")
    func timeRangeSelection() {
        let list = [variable("a", .never),
                    variable("b", .onDashboardLoad),
                    variable("c", .onTimeRangeChanged)]
        let selected = VariableResolver.variablesToRefresh(list, onTimeRangeChange: true)
        #expect(selected.map(\.name) == ["c"])
    }

    @Test("the selection keeps dashboard order")
    func selectionKeepsOrder() {
        let list = [variable("z", .onTimeRangeChanged),
                    variable("m", .onDashboardLoad),
                    variable("a", .onTimeRangeChanged)]
        #expect(VariableResolver.variablesToRefresh(list, onTimeRangeChange: false)
            .map(\.name) == ["z", "m", "a"])
    }
}
