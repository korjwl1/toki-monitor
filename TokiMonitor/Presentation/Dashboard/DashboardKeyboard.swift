import SwiftUI

// MARK: - The dashboard's keyboard
//
// FR-062: every interactive element must be reachable by keyboard. Tab order
// gets a reader to the controls; it does not make the ones behind a menu or a
// popover quick, and on a dashboard the frequent actions are exactly those —
// refresh, time range, edit.
//
// The map is a value rather than a scattering of `.keyboardShortcut` calls so
// that a test can hold two properties nobody can hold by reading: that no two
// commands claim the same chord, and that the list is the same list the toolbar
// draws. A duplicate shortcut is not a compile error and not a visible bug —
// one of the two silently stops working.

/// A keyboard-reachable dashboard action.
enum DashboardCommand: String, CaseIterable, Identifiable, Sendable {
    /// Run every panel's query now.
    case refresh
    /// Open the time range picker.
    case timeRange
    /// Halve the visible time range about its centre.
    case zoomIn
    /// Double it.
    case zoomOut
    /// Slide the range back by half a window.
    case panBackward
    /// Slide it forward, stopping at now.
    case panForward
    /// Enter or leave edit mode.
    case toggleEdit
    /// Add a panel (edit mode only).
    case addPanel
    /// Add a row (edit mode only).
    case addRow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .refresh:     return L.tr("지금 새로고침", "Refresh now")
        case .timeRange:   return L.tr("시간 범위", "Time range")
        case .zoomIn:      return L.tr("시간 범위 확대", "Zoom in")
        case .zoomOut:     return L.tr("시간 범위 축소", "Zoom out")
        case .panBackward: return L.tr("이전 구간", "Earlier")
        case .panForward:  return L.tr("다음 구간", "Later")
        case .toggleEdit:  return L.tr("편집 모드 전환", "Toggle edit mode")
        case .addPanel:    return L.tr("패널 추가", "Add panel")
        case .addRow:      return L.tr("행 추가", "Add row")
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .refresh:     return "r"
        case .timeRange:   return "t"
        // `-` and `=` are the pair every browser and map uses for zoom; `+`
        // would need shift and would collide with `=`'s own chord.
        case .zoomIn:      return "="
        case .zoomOut:     return "-"
        case .panBackward: return .leftArrow
        case .panForward:  return .rightArrow
        case .toggleEdit:  return "e"
        case .addPanel:    return "a"
        case .addRow:      return "n"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .refresh, .timeRange, .zoomIn, .zoomOut:
            return .command
        case .panBackward, .panForward:
            return [.command, .option]
        case .toggleEdit, .addPanel, .addRow:
            // Shift on the three that CHANGE the dashboard. ⌘E, ⌘A and ⌘N are
            // spoken for by the system's own meanings, and an edit-mode toggle
            // that fires when someone meant Select All is a bad afternoon.
            return [.command, .shift]
        }
    }

    /// Whether the command only exists while the dashboard is being edited.
    var requiresEditMode: Bool {
        switch self {
        case .addPanel, .addRow: return true
        default: return false
        }
    }

    /// The chord, for a `.help` tooltip — "⌘R". Assistive technology reads the
    /// button's own label; this is for the reader who can see it and does not
    /// know the shortcut exists.
    var chordDescription: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case .leftArrow:  out += "←"
        case .rightArrow: out += "→"
        default:          out += String(key.character).uppercased()
        }
        return out
    }
}

extension View {
    /// Attach a command's chord and name it in the tooltip.
    func dashboardCommand(_ command: DashboardCommand) -> some View {
        self
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .help("\(command.title) (\(command.chordDescription))")
            .accessibilityLabel(command.title)
    }
}
