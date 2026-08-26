import SwiftUI
import AppKit

/// Unified design system based on 8pt grid + modular scale 1.125.
enum DS {
    // MARK: - Spacing (8pt grid)
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    // MARK: - Typography (modular scale 1.125 — compact UI)
    static let fontTitle: CGFloat = 14
    static let fontBody: CGFloat = 12
    static let fontCaption: CGFloat = 10
    static let fontTiny: CGFloat = 9

    // MARK: - Border Radius (nested: inner = outer - padding)
    static let panelRadius: CGFloat = 14
    static let widgetRadius: CGFloat = 10   // 14 - 4(gap)
    static let btnRadius: CGFloat = 8

    // MARK: - Colors
    static let dividerColor = Color.primary.opacity(0.1)

    // MARK: - Measured foreground tokens (FR-058, 계약 R6)
    //
    // Named tokens rather than `.secondary` / `.tertiary` at each call site.
    // The system label colours are a scale of alphas, and the ones below the
    // top two do not clear the contrast floors on the ground these panels sit
    // on: measured against a panel over #F5F5F5 / #1C1C1C, `.secondary` is
    // 3.05:1 in light and `.tertiary` is 1.87:1 — the first is legal for an
    // axis and not for a sentence, the second is legal for nothing.
    //
    // `ContrastTests` measures every token here, in both appearances, against
    // both the plain ground and the closest surface the panel material reaches.
    // The ratios in the doc comments come from that test, not from an eyeball.

    /// Body text that is not the primary line: a detail sentence, a subtitle,
    /// a badge. Held to the 4.5:1 text floor.
    static let bodySecondary = Color.primary.opacity(0.72)

    /// Icons, axis labels, legend text and other non-text marks. Held to the
    /// 3:1 floor — and comfortably over it, because these are small and thin.
    static let iconSecondary = Color.primary.opacity(0.55)

    /// A border that carries meaning — an edit-mode outline, a table header
    /// rule. Also 3:1: a boundary a reader cannot find is not a boundary.
    ///
    /// The same alpha as `iconSecondary` and named separately anyway: they are
    /// held to the same floor for different reasons, and a later change to one
    /// should not silently move the other.
    static let borderStrong = Color.primary.opacity(0.55)

    // MARK: - Menu Bar
    enum Menu {
        static let leftWidth: CGFloat = 200
        static let rightWidth: CGFloat = 56
        static let btnSize: CGFloat = 56
        static let chartHeight: CGFloat = 32
    }

    // MARK: - Dashboard
    enum Dashboard {
        static let gridPadding: CGFloat = 16
        static let gridSpacing: CGFloat = 8
        static let panelTitleFont: CGFloat = 13
    }
}

// MARK: - Threshold colours

extension DS {
    /// The hex behind each `ThresholdColor`, per appearance.
    ///
    /// The set is closed so that this table can exist: every token is measured
    /// once, here, against the ground the panels actually sit on — the snapshot
    /// harness paints white 0.96 (#F5F5F5) under a light panel and white 0.11
    /// (#1C1C1C) under a dark one. A free-string colour cannot be measured at
    /// all, which is why R6 forbids one.
    ///
    /// WCAG 2.1 contrast, against #F5F5F5 in light and #1C1C1C in dark:
    ///
    /// | token   | light hex | ratio | dark hex  | ratio |
    /// |---------|-----------|-------|-----------|-------|
    /// | green   | #177245   | 5.46  | #3FB950   | 6.71  |
    /// | yellow  | #7A6100   | 5.45  | #E3B341   | 8.76  |
    /// | orange  | #9A4F00   | 5.52  | #F0883E   | 6.73  |
    /// | red     | #C0242C   | 5.46  | #FF7B72   | 6.76  |
    /// | blue    | #0B62D0   | 5.25  | #58A6FF   | 6.75  |
    /// | purple  | #6E40C9   | 5.95  | #B08CFF   | 6.53  |
    /// | neutral | #57606A   | 5.86  | #A0A0A6   | 6.55  |
    ///
    /// Every one clears 4.5:1, so a threshold colour is legal as body text as
    /// well as for the 3:1 non-text uses (bands, spans, rules) — a stat card
    /// tinting its own number is the reason the stricter floor is the one
    /// applied. The panel material lightens a light ground and darkens a dark
    /// one by a few percent; the closest surface either direction reaches
    /// (#ECECEE / #323234) still leaves every token at 4.85:1 or better.
    ///
    /// Colour is never the only carrier: every render that uses one prints or
    /// speaks `Thresholds.label(for:steps:)` beside it.
    static func threshold(_ token: ThresholdColor, dark: Bool) -> Color {
        Color(hex: dark ? token.darkHex : token.lightHex)
    }

    /// The same colour for a context that has no `ColorScheme` to consult —
    /// resolved dynamically by AppKit, so it still follows the appearance.
    ///
    /// One instance per token, kept: a dynamic `NSColor` compares by identity,
    /// so building a fresh one per call would make two requests for the same
    /// token unequal — and "is this arc the red band" is a question both the
    /// tests and SwiftUI's diffing ask.
    static func threshold(_ token: ThresholdColor) -> Color {
        dynamicThresholds[token] ?? .primary
    }

    /// A series colour written on a field override.
    ///
    /// The editor offers the same measured tokens the thresholds use, so a
    /// colour a reader picks here is one whose contrast is known. A string from
    /// somewhere else — a Grafana export's `#7EB26D` — is honoured as written:
    /// its author chose it, and refusing to draw it would lose more than it
    /// protects. Anything unreadable returns nil and the palette assigns.
    static func seriesColor(_ raw: String?) -> Color? {
        guard let raw, !raw.isEmpty else { return nil }
        if let token = ThresholdColor.named(raw) { return threshold(token) }
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(hex: value)
    }

    private static let dynamicThresholds: [ThresholdColor: Color] = Dictionary(
        uniqueKeysWithValues: ThresholdColor.allCases.map { token in
            (token, Color(nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(Color(hex: dark ? token.darkHex : token.lightHex))
            }))
        }
    )
}

extension ThresholdColor {
    /// Measured against #F5F5F5 — see `DS.threshold(_:dark:)`.
    var lightHex: UInt32 {
        switch self {
        case .green:   return 0x177245
        case .yellow:  return 0x7A6100
        case .orange:  return 0x9A4F00
        case .red:     return 0xC0242C
        case .blue:    return 0x0B62D0
        case .purple:  return 0x6E40C9
        case .neutral: return 0x57606A
        }
    }

    /// Measured against #1C1C1C — see `DS.threshold(_:dark:)`.
    var darkHex: UInt32 {
        switch self {
        case .green:   return 0x3FB950
        case .yellow:  return 0xE3B341
        case .orange:  return 0xF0883E
        case .red:     return 0xFF7B72
        case .blue:    return 0x58A6FF
        case .purple:  return 0xB08CFF
        case .neutral: return 0xA0A0A6
        }
    }
}

extension Color {
    /// 0xRRGGBB. Private to the threshold palette's needs — this app has no
    /// other place where a colour is written as a number, and it should not
    /// grow one: a colour that is not in a measured set does not belong on a
    /// panel.
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
