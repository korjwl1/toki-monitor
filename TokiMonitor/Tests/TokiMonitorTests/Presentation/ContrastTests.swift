import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - Measured contrast over the dashboard's colour tokens
//
// SC-006 asks for MEASURED values, not an assurance, and FR-058 / 계약 R6 set
// the two floors: 4.5:1 for body text, 3:1 for axes, legends, borders and
// icons — in BOTH appearances.
//
// The threshold palette was measured this way already (`DS.threshold(_:dark:)`
// carries the table). This extends the same method to the foreground tokens the
// rest of the dashboard draws with, which is where the failures actually were:
// the system's `.secondary` label reads 3.05:1 on a light panel and `.tertiary`
// reads 1.69:1, so every sentence set in `.secondary` was under the text floor
// and every icon set in `.tertiary` was under the non-text floor.
//
// Each token is measured against four grounds — the plain light and dark
// backdrops, and the closest-to-mid-grey surface the panel material reaches in
// each — because a translucent card moves the ground under the text and the
// worst of the four is the one that has to clear the bar.

/// WCAG 2.1 relative luminance and contrast.
///
/// Shared with `PanelRaster`, which measures the same quantities over rendered
/// pixels. Two implementations of a formula whose whole job is to be the
/// arbiter would be one implementation too many.
enum WCAG {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A partly transparent foreground laid over an opaque ground.
    ///
    /// This is the step that cannot be skipped here: every token below is a
    /// label colour at some alpha, and its ratio is a fact about the pair, not
    /// about the colour.
    static func composite(_ fg: RGB, alpha: Double, over bg: RGB) -> RGB {
        RGB(r: fg.r * alpha + bg.r * (1 - alpha),
            g: fg.g * alpha + bg.g * (1 - alpha),
            b: fg.b * alpha + bg.b * (1 - alpha))
    }

    /// Resolve a SwiftUI colour the way AppKit would draw it in one appearance.
    ///
    /// `Color.primary` is a dynamic colour: asking it for components outside a
    /// drawing appearance gives whichever one happens to be current, which in a
    /// test is the machine's setting rather than the case under test.
    @MainActor
    static func resolve(_ color: Color, dark: Bool) -> (rgb: RGB, alpha: Double) {
        var out = (rgb: RGB(r: 0, g: 0, b: 0), alpha: 1.0)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let read = {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = (RGB(r: Double(ns.redComponent),
                       g: Double(ns.greenComponent),
                       b: Double(ns.blueComponent)),
                   Double(ns.alphaComponent))
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(read)
        } else {
            read()
        }
        return out
    }
}

/// What a token is used for, and therefore which floor it has to clear.
enum ContrastRole: String, CaseIterable, Sendable {
    /// A sentence, a number, a label someone reads. 4.5:1.
    case bodyText
    /// An axis label, a legend swatch, a border, an icon. 3:1.
    case nonText
    /// Carries no information on its own. No floor — and each member has to
    /// say, below, what else carries what it might have carried.
    case decorative

    var floor: Double? {
        switch self {
        case .bodyText: return 4.5
        case .nonText: return 3.0
        case .decorative: return nil
        }
    }
}

/// One ground a token gets drawn on.
struct ContrastGround: Sendable {
    let name: String
    let dark: Bool
    let rgb: WCAG.RGB

    /// The dashboard's two backdrops, plus the surface each one's panel
    /// material pulls towards mid-grey — the worst case for anything drawn on
    /// a card. The four hexes are the ones `DS.threshold(_:dark:)` already
    /// records, so the two tables are measured against the same thing.
    static let all: [ContrastGround] = [
        ContrastGround(name: "light #F5F5F5", dark: false, rgb: hex(0xF5F5F5)),
        ContrastGround(name: "light panel #ECECEE", dark: false, rgb: hex(0xECECEE)),
        ContrastGround(name: "dark #1C1C1C", dark: true, rgb: hex(0x1C1C1C)),
        ContrastGround(name: "dark panel #323234", dark: true, rgb: hex(0x323234)),
    ]

    static func hex(_ value: UInt32) -> WCAG.RGB {
        WCAG.RGB(r: Double((value >> 16) & 0xFF) / 255,
                 g: Double((value >> 8) & 0xFF) / 255,
                 b: Double(value & 0xFF) / 255)
    }
}

/// A token, its role, and where it is drawn.
struct ContrastToken: Sendable {
    let name: String
    let color: Color
    let role: ContrastRole
    /// Why it is decorative, for the tokens that are. Required of them and of
    /// nothing else: "this one does not have to clear the bar" is a claim, and
    /// a claim with no reason beside it is how a floor stops meaning anything.
    var exemption: String?
}

@Suite("Colour token contrast", .serialized)
@MainActor
struct ContrastTests {

    /// Every foreground token the dashboard draws with.
    static let tokens: [ContrastToken] = [
        ContrastToken(name: "DS body (Color.primary)", color: Color.primary, role: .bodyText),
        ContrastToken(name: "DS.bodySecondary", color: DS.bodySecondary, role: .bodyText),
        ContrastToken(name: "DS.iconSecondary", color: DS.iconSecondary, role: .nonText),
        ContrastToken(name: "DS.borderStrong", color: DS.borderStrong, role: .nonText),
        ContrastToken(
            name: "DS.dividerColor", color: DS.dividerColor, role: .decorative,
            exemption: "A hairline between a panel's title and its content. The "
                + "gap and the title's weight already separate them; removing "
                + "the rule loses nothing a reader needs."
        ),
    ]

    /// The system label colours, measured and NOT used as dashboard tokens.
    ///
    /// Kept in the suite because the measurement is the reason they are not
    /// used: without it, `.secondary` is an obvious choice for a subtitle and
    /// stays one until someone measures it.
    static let systemLabels: [(name: String, color: Color, floorItFails: Double)] = [
        ("system .secondary", Color.secondary, 4.5),
        ("system .tertiary", Color.primary.opacity(0.26), 3.0),
    ]

    /// Two decimals, for a message a person reads.
    private func rounded(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func ratio(_ token: ContrastToken, on ground: ContrastGround) -> Double {
        let resolved = WCAG.resolve(token.color, dark: ground.dark)
        let over = WCAG.composite(resolved.rgb, alpha: resolved.alpha, over: ground.rgb)
        return WCAG.contrast(over, ground.rgb)
    }

    @Test("every token clears the floor its role sets, on every ground")
    func tokensClearTheirFloor() {
        var report: [String] = []
        for token in Self.tokens {
            for ground in ContrastGround.all {
                let measured = ratio(token, on: ground)
                report.append(String(format: "%@ on %@: %.2f:1 (%@)",
                                     token.name, ground.name, measured,
                                     token.role.rawValue))
                guard let floor = token.role.floor else { continue }
                #expect(measured >= floor,
                        "\(token.name) on \(ground.name) measures \(rounded(measured)):1, below the \(floor):1 floor for \(token.role.rawValue)")
            }
        }
        // Printed, not just asserted: SC-006 asks for the values.
        print("== token contrast ==\n" + report.joined(separator: "\n"))
    }

    @Test("a decorative token says why it is exempt")
    func decorativeTokensAreJustified() {
        for token in Self.tokens where token.role == .decorative {
            #expect(token.exemption?.isEmpty == false,
                    "\(token.name) is exempt from the contrast floor with no reason given")
        }
    }

    @Test("every threshold colour is legible as text, in both appearances")
    func thresholdPaletteIsLegible() {
        var report: [String] = []
        for token in ThresholdColor.allCases {
            for ground in ContrastGround.all {
                let color = DS.threshold(token, dark: ground.dark)
                let resolved = WCAG.resolve(color, dark: ground.dark)
                let measured = WCAG.contrast(
                    WCAG.composite(resolved.rgb, alpha: resolved.alpha, over: ground.rgb),
                    ground.rgb
                )
                report.append(String(format: "%@ on %@: %.2f:1",
                                     token.rawValue, ground.name, measured))
                // The stricter floor, not 3:1 — a stat card tints its own
                // number with these, so a threshold colour is body text.
                #expect(measured >= 4.5,
                        "threshold \(token.rawValue) on \(ground.name) measures \(rounded(measured)):1, below 4.5:1")
            }
        }
        print("== threshold contrast ==\n" + report.joined(separator: "\n"))
    }

    @Test("the system label colours the dashboard avoids are the reason it avoids them")
    func systemLabelsFallShort() {
        var report: [String] = []
        for entry in Self.systemLabels {
            let worst = ContrastGround.all.map { ground -> Double in
                let resolved = WCAG.resolve(entry.color, dark: ground.dark)
                return WCAG.contrast(
                    WCAG.composite(resolved.rgb, alpha: resolved.alpha, over: ground.rgb),
                    ground.rgb
                )
            }.min() ?? 0
            report.append(String(format: "%@: worst %.2f:1 (floor %.1f)",
                                 entry.name, worst, entry.floorItFails))
            #expect(worst < entry.floorItFails,
                    "\(entry.name) now clears \(entry.floorItFails):1 — if the platform changed, the DS tokens that exist to replace it can go")
        }
        print("== system labels ==\n" + report.joined(separator: "\n"))
    }

    @Test("the contrast formula agrees with the WCAG reference pairs")
    func formulaIsCorrect() {
        // Black on white is exactly 21:1 and white on white is exactly 1:1.
        // Without these two the rest of this file measures its own arithmetic.
        let white = WCAG.RGB(r: 1, g: 1, b: 1)
        let black = WCAG.RGB(r: 0, g: 0, b: 0)
        #expect(abs(WCAG.contrast(black, white) - 21) < 0.001)
        #expect(abs(WCAG.contrast(white, white) - 1) < 0.001)
        // #767676 on white is the canonical 4.5:1 boundary colour.
        let boundary = ContrastGround.hex(0x767676)
        #expect(abs(WCAG.contrast(boundary, white) - 4.54) < 0.01)
        // Compositing a 50% black over white lands halfway in sRGB space.
        let half = WCAG.composite(black, alpha: 0.5, over: white)
        #expect(abs(half.r - 0.5) < 0.0001)
    }
}
