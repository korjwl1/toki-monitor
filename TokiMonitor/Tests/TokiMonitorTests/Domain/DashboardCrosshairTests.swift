import Testing
import Foundation
@testable import TokiMonitor

@Suite("Shared crosshair")
@MainActor
struct DashboardCrosshairTests {

    private let instant = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a crosshair starts with nothing marked")
    func startsEmpty() {
        let crosshair = DashboardCrosshair()
        #expect(crosshair.date == nil)
        #expect(!crosshair.isActive)
    }

    @Test("pointing at one panel marks the instant for every panel")
    func oneInstantForAll() {
        let crosshair = DashboardCrosshair()
        let a = UUID(), b = UUID()
        crosshair.move(to: instant, panelID: a)
        #expect(crosshair.date == instant)
        #expect(crosshair.isActive, "panel B draws the rule too — that is the point")
        #expect(crosshair.isOwner(a))
        #expect(!crosshair.isOwner(b), "only the panel under the cursor gets the tooltip")
    }

    @Test("leaving a panel the cursor is no longer in does not clear the crosshair")
    func onlyTheOwnerClears() {
        let crosshair = DashboardCrosshair()
        let a = UUID(), b = UUID()
        crosshair.move(to: instant, panelID: b)
        // A leaves as the pointer crosses into B, and its `.ended` can arrive
        // after B's first `.active`. Honouring it would blank the rule B just
        // set — a flicker on every boundary between two charts.
        crosshair.clear(panelID: a)
        #expect(crosshair.date == instant)
        #expect(crosshair.isOwner(b))
    }

    @Test("the owner leaving clears it")
    func ownerClears() {
        let crosshair = DashboardCrosshair()
        let a = UUID()
        crosshair.move(to: instant, panelID: a)
        crosshair.clear(panelID: a)
        #expect(crosshair.date == nil)
        #expect(!crosshair.isActive)
        #expect(!crosshair.isOwner(a))
    }

    @Test("moving to another panel hands ownership over")
    func ownershipMoves() {
        let crosshair = DashboardCrosshair()
        let a = UUID(), b = UUID()
        crosshair.move(to: instant, panelID: a)
        let later = instant.addingTimeInterval(600)
        crosshair.move(to: later, panelID: b)
        #expect(crosshair.date == later)
        #expect(crosshair.isOwner(b))
        #expect(!crosshair.isOwner(a))
    }

    @Test("a panel with no id of its own never claims to be the owner")
    func anonymousPanelIsNeverOwner() {
        let crosshair = DashboardCrosshair()
        crosshair.move(to: instant, panelID: nil)
        // The editor preview has no panel id. It follows the rule like every
        // other chart and must not steal the tooltip from the real panels.
        #expect(crosshair.isActive)
        #expect(!crosshair.isOwner(nil))
        #expect(!crosshair.isOwner(UUID()))
    }
}
