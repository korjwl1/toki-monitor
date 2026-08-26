import SwiftUI

/// One place that decides whether the dashboard animates.
///
/// FR-064 (MUST): with system Reduce Motion on, a chart goes straight to its
/// final state instead of growing out of the axis. Before this the only place
/// in the app that consulted the setting was the menu bar icon
/// (`StatusItemUnit`), and the dashboard had eleven `withAnimation` calls that
/// did not — including the two that matter most, the time series and the bar
/// chart, both of which rebuild their series from zero on every refresh.
///
/// Each kind of motion is named rather than exposing one "the animation"
/// helper, because they are switched off for different reasons and a reader
/// who turns the setting on has different tolerance for each: a chart growing
/// out of the floor is vestibular motion, a control fading in is not. Both are
/// dropped here — the requirement is unconditional — but the distinction is
/// what tells a later reader which ones could ever be kept.
enum Motion {

    /// A control appearing or disappearing: the panel's hover/focus buttons.
    /// Position does not change, only opacity.
    static func reveal(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.15)
    }

    /// Data arriving or changing: chart series, a stat card's digits.
    static func data(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.3)
    }

    /// Data leaving while a query runs.
    static func dataOut(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeIn(duration: 0.15)
    }

    /// Something on screen moving or resizing: entering edit mode, a row
    /// collapsing, the dashboard list rearranging.
    static func layout(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    /// Whether a chart may start its series at zero and grow.
    ///
    /// This is the one that is not a duration. `Motion.data(true)` being nil
    /// makes the jump instant, but the chart would still pass through a frame
    /// drawn at zero — which on a refresh is a flicker to the axis and back.
    /// Under Reduce Motion the series is written once, at its real values.
    static func growsFromZero(_ reduceMotion: Bool) -> Bool { !reduceMotion }
}
