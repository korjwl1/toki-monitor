import SwiftUI

// MARK: - The plan-fit page's visual language
//
// Three things this file exists to fix, all of them named in research §5:
//
// 1. **The hierarchy was inverted.** The verdict — the one sentence the page
//    exists to produce — rendered at 10pt while supporting statistics rendered
//    at 12pt. `UI_UX_DESIGN_REFERENCE.md ## Visual hierarchy` puts size first
//    among differentiators and asks for at least a 1.5x step between levels, so
//    the scale below is built around that step and `ledeToMetricRatio` is
//    asserted in the tests rather than left to a reviewer's eye.
// 2. **Colour carried meaning alone.** Red meant exhausted, orange meant
//    "over 75%", and nothing else said so. Every semantic colour here arrives
//    with a symbol AND a word (FR-058); the colour is the third carrier, never
//    the first.
// 3. **Every card had the same background**, so nothing read as more important
//    than anything else. Surfaces below differ in padding, radius and border as
//    well as fill, so the ordering survives a monochrome render.

// MARK: - Type scale

/// Modular steps for this page. The page's own scale rather than `DS`'s
/// because `DS.fontTitle` (14) is a *panel* title in a 320pt card, and a
/// conclusion that has to out-rank every number on an 800pt page is a
/// different job.
enum PlanFitType {
    /// The conclusion. Nothing else on the page is this size.
    static let lede: CGFloat = 24
    /// A section's name.
    static let sectionTitle: CGFloat = 13
    /// A number the reader is meant to take away.
    static let metric: CGFloat = 15
    static let body: CGFloat = DS.fontBody       // 12
    static let caption: CGFloat = DS.fontCaption // 10
    static let tiny: CGFloat = DS.fontTiny       // 9

    /// The step the design reference asks for between hierarchy levels, held
    /// against the *largest supporting number* rather than against body text —
    /// the metric is what the lede was previously losing to.
    static var ledeToMetricRatio: CGFloat { lede / metric }
    /// The step against ordinary running text.
    static var ledeToBodyRatio: CGFloat { lede / body }
}

// MARK: - Ink

/// Text colours that clear WCAG AA in both appearances.
///
/// Deliberately NOT `.secondary` / `.tertiary`: macOS's secondary label is
/// 50%-alpha black, which composites to roughly 3.9:1 on a light card — under
/// the 4.5:1 that FR-057 requires of body text. These are opacities of the
/// label colour chosen so that the composite stays above the bar in both
/// appearances, and `PlanFitSnapshotTests` measures the rendered pixels rather
/// than trusting the arithmetic.
enum PlanFitInk {
    /// Values, headlines, anything load-bearing. 12.8:1 at worst.
    static let strong = Color.primary
    /// Running text and labels. 5.6:1 light, 6.5:1 dark.
    static let support = Color.primary.opacity(0.72)
    /// Provenance tags, legends, a verdict's basis line, every caveat.
    ///
    /// Held to the 4.5:1 TEXT floor rather than the 3:1 one despite being the
    /// lightest of the three: these are the sentences that stop a number being
    /// misread, and a caveat nobody can read is a caveat that is not there.
    /// It was 0.6 and measured 3.92:1 in the deepest card — under the floor on
    /// every light ground the page builds. 4.6:1 light, 5.5:1 dark.
    static let faint = Color.primary.opacity(0.68)
}

// MARK: - Provenance (T052 / FR-047, FR-049)

/// Where a number on this page came from.
///
/// The distinction is not decoration. `activeMs` is accumulated in daemon
/// memory and restarts with the daemon, so every figure derived from it is a
/// floor and printing it as though it were exact would misreport the one axis
/// the plan verdict rests on.
enum Provenance: String, CaseIterable, Sendable, Hashable {
    /// Reported by the provider and stored on the row.
    case observed
    /// Computed by this app from observed values.
    case derived
    /// The true value is at least this; the recording can only understate it.
    case lowerBound

    var label: String {
        switch self {
        case .observed: return L.tr("관측", "observed")
        case .derived: return L.tr("파생", "derived")
        case .lowerBound: return L.tr("하한", "at least")
        }
    }

    /// A word AND a shape, so the tag never depends on colour (FR-058).
    var symbolName: String {
        switch self {
        case .observed: return "eye"
        case .derived: return "function"
        case .lowerBound: return "arrow.up"
        }
    }

    var explanation: String {
        switch self {
        case .observed:
            return L.tr(
                "공급자가 보고해 행에 저장된 값입니다.",
                "Reported by the provider and stored on the window row."
            )
        case .derived:
            return L.tr(
                "관측값에서 이 앱이 계산한 값입니다.",
                "Computed by this app from observed values."
            )
        case .lowerBound:
            return L.tr(
                "실제 값은 이보다 크거나 같습니다 — 기록이 과소 집계될 수는 있어도 과대 집계되지는 않습니다.",
                "The real value is at or above this — the recording can understate it but never overstate it."
            )
        }
    }
}

/// The tag rendered beside a number.
struct ProvenanceTag: View {
    let provenance: Provenance

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: provenance.symbolName)
                .font(.system(size: PlanFitType.tiny, weight: .semibold))
            Text(provenance.label)
                .font(.system(size: PlanFitType.tiny))
        }
        .foregroundStyle(PlanFitInk.faint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provenance.label)
        .accessibilityHint(provenance.explanation)
    }
}

/// The legend that makes the three tags mean something the first time they are
/// seen. One line, at the foot of the page.
struct ProvenanceLegend: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.md) {
            ForEach(Provenance.allCases, id: \.self) { provenance in
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    ProvenanceTag(provenance: provenance)
                    Text(provenance.explanation)
                        .font(.system(size: PlanFitType.tiny))
                        .foregroundStyle(PlanFitInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - What VoiceOver says about a figure (T072 / FR-060)

/// One figure, spoken in three parts.
///
/// **A number without its provenance is worse on this page than elsewhere**,
/// because this page recommends things about money. "85%" read on its own is
/// indistinguishable from "85% or more, over a sample of five windows, four of
/// which the machine slept through" — and only one of those is worth acting
/// on. A sighted reader gets the difference from the provenance tag and the
/// sample line sitting beside the number; a VoiceOver reader gets it only if
/// something puts it there.
///
/// So all three parts are stored and non-optional, and `basis` is required to
/// name the figure's provenance. There is no initialiser that produces a
/// figure's speech without saying what the figure stands on, and
/// `PlanFitVoiceOverTests` walks a built page asserting every one of them.
struct PlanFitFigureSpeech: Equatable, Hashable, Sendable {
    /// What the figure is. Read first, as the element's label.
    let meaning: String
    /// The figure itself. Read as the element's value, so VoiceOver's
    /// "label, value" cadence puts the meaning before the number.
    let value: String
    /// What it stands on: provenance, sample size, exclusions. Read as the
    /// hint, which VoiceOver speaks after a beat.
    let basis: String

    /// The one initialiser. `provenance` is a parameter rather than something
    /// the caller may fold into `detail`, so a figure cannot be given speech
    /// that omits where its number came from.
    init(meaning: String, value: String, provenance: Provenance, detail: String? = nil) {
        self.meaning = meaning
        self.value = value
        var basis = "\(provenance.label) · \(provenance.explanation)"
        if let detail, !detail.isEmpty { basis = "\(detail) · \(basis)" }
        self.basis = basis
    }
}

extension View {
    /// Collapse a figure and its surroundings into one spoken element.
    ///
    /// `children: .ignore` is deliberate: without it VoiceOver reads the
    /// number, then the label, then the provenance tag, then the sample line
    /// as four separate stops, and the reader has to assemble the meaning from
    /// four swipes in whatever order the layout happens to produce.
    func planFitFigure(_ speech: PlanFitFigureSpeech) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(speech.meaning)
            .accessibilityValue(speech.value)
            .accessibilityHint(speech.basis)
    }
}

// MARK: - Keyboard (T071 / FR-060)

/// The keys the page answers to, as a value the tests can ask directly.
///
/// The mapping lives here rather than inside a `.onKeyPress` closure so that
/// "left arrow moves to the previous period unit" is a fact a test states,
/// not a fact a reviewer takes on trust from a view body nobody can run
/// headlessly.
enum PlanFitKeyboard {

    /// Where a key press moves the period unit, or nil when the key means
    /// nothing to this page and should fall through to the scroll view.
    ///
    /// Arrow keys because the segmented picker uses them when it holds focus,
    /// and the page should not behave differently depending on which of its
    /// two focus stops the reader is on. Brackets because they reach the same
    /// thing without leaving the home row.
    static func unit(movingFrom current: PeriodUnit, key: KeyEquivalent) -> PeriodUnit? {
        let order = PeriodUnit.allCases
        guard let index = order.firstIndex(of: current) else { return nil }
        switch key {
        case .leftArrow, "[":
            return index > 0 ? order[index - 1] : nil
        case .rightArrow, "]":
            return index + 1 < order.count ? order[index + 1] : nil
        default:
            return nil
        }
    }

    /// What the page tells a reader about its own keyboard, once, beside the
    /// control the keys drive.
    static var hint: String {
        L.tr(
            "← → 또는 [ ] 로 기간 단위를 바꿉니다",
            "← → or [ ] switch the period unit"
        )
    }
}

// MARK: - Surfaces

/// Card weights. The page has exactly three, and they differ in more than
/// fill so the ordering is legible without colour.
enum PlanFitSurface {
    /// The conclusion. One per page.
    case lede
    /// A section of supporting evidence.
    case section
    /// A card nested inside a section.
    case inner

    var fill: Color {
        switch self {
        case .lede: return Color.primary.opacity(0.06)
        case .section: return Color.primary.opacity(0.035)
        case .inner: return Color.primary.opacity(0.02)
        }
    }

    var stroke: Color {
        switch self {
        case .lede: return Color.primary.opacity(0.16)
        case .section: return Color.primary.opacity(0.07)
        case .inner: return Color.primary.opacity(0.05)
        }
    }

    var radius: CGFloat {
        switch self {
        case .lede: return DS.panelRadius
        case .section: return DS.widgetRadius
        case .inner: return DS.btnRadius
        }
    }

    var padding: CGFloat {
        switch self {
        case .lede: return DS.xl
        case .section: return DS.lg
        case .inner: return DS.md
        }
    }
}

private struct PlanFitCard: ViewModifier {
    let surface: PlanFitSurface

    func body(content: Content) -> some View {
        content
            .padding(surface.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: surface.radius, style: .continuous)
                    .fill(surface.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: surface.radius, style: .continuous)
                    .strokeBorder(surface.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func planFitCard(_ surface: PlanFitSurface) -> some View {
        modifier(PlanFitCard(surface: surface))
    }
}

// MARK: - Section heading

/// A section's name plus the one sentence that says what the section is for.
struct PlanFitSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: PlanFitType.sectionTitle, weight: .semibold))
                .foregroundStyle(PlanFitInk.strong)
                // T071/T072: VoiceOver's heading rotor is how a reader moves
                // between the page's sections without swiping through every
                // figure in each of them.
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Semantic marks

/// A fact that carries a warning, rendered as symbol + word + colour, in that
/// order of importance. Removing the colour must not remove the meaning.
struct PlanFitMark: View {
    enum Tone: Equatable {
        case neutral
        case attention
        case blocked

        var symbolName: String {
            switch self {
            case .neutral: return "circle"
            case .attention: return "exclamationmark.triangle.fill"
            case .blocked: return "octagon.fill"
            }
        }

        /// Reinforcement only. `Color.primary` in the neutral case means a
        /// monochrome render loses nothing but emphasis.
        var color: Color {
            switch self {
            case .neutral: return PlanFitInk.support
            // Not `.orange` / `.red`: the system accents drop under 4.5:1 on a
            // light background. These are darkened for light mode and lifted
            // for dark, resolved through the appearance rather than fixed.
            // The light value is darker than it looks like it needs to be:
            // 0.62/0.36/0 clears 4.5:1 on the bare page and measures 4.32:1
            // inside the lede card, which is where the page's most important
            // warning is actually drawn (`PlanFitContrastTests`).
            case .attention: return Color(nsColor: .init(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .init(srgbRed: 1.0, green: 0.70, blue: 0.28, alpha: 1)
                    : .init(srgbRed: 0.56, green: 0.33, blue: 0.0, alpha: 1)
            })
            case .blocked: return Color(nsColor: .init(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .init(srgbRed: 1.0, green: 0.55, blue: 0.52, alpha: 1)
                    : .init(srgbRed: 0.70, green: 0.13, blue: 0.10, alpha: 1)
            })
            }
        }
    }

    let tone: Tone
    let text: String
    var size: CGFloat = PlanFitType.body

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
            Image(systemName: tone.symbolName)
                .font(.system(size: size * 0.82, weight: .semibold))
            Text(text)
                .font(.system(size: size, weight: tone == .neutral ? .regular : .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone.color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting

enum PlanFitFormat {

    /// A percentage that cannot trap on a garbage wire value.
    static func pct(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(min(max(value, 0), 9_999).rounded()))%"
    }

    /// A percentage that is known only as a floor.
    static func pctAtLeast(_ value: Double?, isLowerBound: Bool) -> String {
        guard let value, value.isFinite else { return "—" }
        return (isLowerBound ? "≥" : "") + pct(value)
    }

    static func duration(ms: Int64) -> String {
        duration(seconds: Double(ms) / 1000)
    }

    static func duration(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 {
            return L.tr("\(hours / 24)일 \(hours % 24)시간", "\(hours / 24)d \(hours % 24)h")
        }
        if hours > 0 {
            return L.tr("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m")
        }
        return L.tr("\(minutes)분", "\(minutes)m")
    }

    /// Hours, to one decimal below ten so a short week does not read as zero.
    static func hours(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return L.tr("0시간", "0h") }
        if value < 10 { return L.tr("\(String(format: "%.1f", value))시간", "\(String(format: "%.1f", value))h") }
        return L.tr("\(Int(value.rounded()))시간", "\(Int(value.rounded()))h")
    }

    /// A signed rate of change. Never an absolute difference (FR-008).
    static func changeRate(_ pct: Double?) -> String? {
        guard let pct, pct.isFinite else { return nil }
        let rounded = Int(pct.rounded())
        return rounded >= 0 ? "+\(rounded)%" : "\(rounded)%"
    }

    /// `@MainActor` because it already was in fact — it resolves the app's
    /// language through `L.code`, which reaches `MainActor.assumeIsolated` and
    /// traps rather than returning when called off the main actor. The
    /// annotation moves that from a runtime trap to a compile-time check.
    @MainActor
    static func day(_ ms: Int64) -> String {
        // Cached: this is called once per row from a builder that runs inside
        // a SwiftUI body, and building a DateFormatter is not cheap.
        FormatterCache
            .templated("MdE", localeID: FormatterCache.currentLocaleID)
            .string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Delegates to `ProviderRegistry`, which already maps toki schemas to
    /// providers. This used to be a second copy of that mapping.
    static func providerTitle(_ name: String) -> String {
        ProviderRegistry.toolTitle(forSchema: name)
    }

    static func limitTitle(provider: String, kind: String, limitId: String) -> String {
        switch limitId {
        case "five_hour": return L.tr("5시간", "5-hour")
        case "seven_day": return L.tr("주간", "Weekly")
        case "seven_day_sonnet": return L.tr("주간 · Sonnet", "Weekly · Sonnet")
        case "seven_day_opus": return L.tr("주간 · Opus", "Weekly · Opus")
        case "codex", "":
            return kind == "session" ? L.tr("5시간", "5-hour") : L.tr("주간", "Weekly")
        default:
            let base = kind == "session" ? L.tr("5시간", "5-hour") : L.tr("주간", "Weekly")
            return "\(base) · \(limitId)"
        }
    }
}
