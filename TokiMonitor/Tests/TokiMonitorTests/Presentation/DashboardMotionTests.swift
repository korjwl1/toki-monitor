import Testing
import Foundation
import SwiftUI
@testable import TokiMonitor

@Suite("Reduce Motion and the dashboard keyboard")
@MainActor
struct DashboardMotionTests {

    // MARK: - FR-064

    @Test("with Reduce Motion on, nothing on the dashboard animates")
    func reduceMotionSilencesEverything() {
        #expect(Motion.reveal(true) == nil)
        #expect(Motion.data(true) == nil)
        #expect(Motion.dataOut(true) == nil)
        #expect(Motion.layout(true) == nil)
    }

    @Test("with it off, each kind of motion still has its own duration")
    func normallyAnimated() {
        #expect(Motion.reveal(false) != nil)
        #expect(Motion.data(false) != nil)
        #expect(Motion.dataOut(false) != nil)
        #expect(Motion.layout(false) != nil)
    }

    @Test("a chart does not grow out of the axis under Reduce Motion")
    func chartsDoNotGrow() {
        // The one that is not a duration: `withAnimation(nil)` still passes
        // through the zero-valued frame, which on every refresh is a flick down
        // to the axis and back.
        #expect(!Motion.growsFromZero(true))
        #expect(Motion.growsFromZero(false))
    }

    // MARK: - FR-062

    @Test("no two keyboard commands claim the same chord")
    func chordsAreUnique() {
        let chords = DashboardCommand.allCases.map {
            "\($0.modifiers.rawValue)-\($0.key.character)"
        }
        #expect(Set(chords).count == chords.count,
                "a duplicate shortcut is neither a compile error nor a visible bug — one of the two silently stops working: \(chords)")
    }

    @Test("every command is named, in both the tooltip and the rotor")
    func commandsAreNamed() {
        for command in DashboardCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(command.chordDescription.contains("⌘"),
                    "\(command.rawValue) has no command key — it would fire while typing")
            #expect(command.chordDescription.count >= 2)
        }
    }

    @Test("the destructive-ish commands take shift, so they cannot be hit by accident")
    func editingCommandsAreShifted() {
        for command in DashboardCommand.allCases where command.requiresEditMode {
            #expect(command.modifiers.contains(.shift),
                    "\(command.rawValue) shares a chord with a system action")
        }
        #expect(DashboardCommand.toggleEdit.modifiers.contains(.shift))
    }

    @Test("the arrow commands are the pan pair and nothing else")
    func arrowsArePanOnly() {
        let arrows = DashboardCommand.allCases.filter {
            $0.key == .leftArrow || $0.key == .rightArrow
        }
        #expect(Set(arrows.map(\.rawValue)) == ["panBackward", "panForward"])
    }
}
