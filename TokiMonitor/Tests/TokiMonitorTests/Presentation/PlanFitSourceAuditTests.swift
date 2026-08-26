import Testing
import Foundation
import SwiftUI
@testable import TokiMonitor

// MARK: - Two absences, proved over the sources (T069, T077)
//
// Both of these tasks assert that something is NOT in the code. A test over
// behaviour can only ever say "the paths I thought to call did not do it", so
// these read the sources themselves — located from `#filePath`, which the
// compiler fills in with this file's own absolute path.
//
// **T069 — no tier's absolute limit anywhere in `Domain/`.** Providers expose
// exhaustion as a *percentage* and never publish the limit it is a percentage
// of, so any absolute figure in this app would be a copied number: constitution
// principle II forbids it, contract V7 restates it, and community tools that
// carry one go quietly wrong when the provider moves it. The scan below looks
// for the two shapes such a number can take — a constant whose NAME says it is
// a limit, and a tier string sitting next to a magnitude — and there is a
// behavioural counterpart in `SubscriptionComparisonTests.planStringChangesNothing`
// which proves no known tier behaves differently from an invented one.
//
// **T077 — no cohort or peer comparison anywhere in the plan-fit page.** It
// would need a cohort this product does not have and could not get without
// sending the user's usage somewhere (constitution principle I, FR-050). The
// scan is deliberately run over CODE with comments and localized copy removed,
// because the page's own text says "nothing here compares you with anyone
// else" — a scan that reads the copy finds the promise and calls it a
// violation.

/// The Swift sources, found from this file's compile-time path.
enum SourceTree {

    /// `<repo>/TokiMonitor`, i.e. the directory holding `Domain/`,
    /// `Presentation/` and `Tests/`.
    static var root: URL {
        // .../TokiMonitor/Tests/TokiMonitorTests/Presentation/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Presentation
            .deletingLastPathComponent()   // TokiMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TokiMonitor
    }

    /// Every `.swift` file under `root/<subpath>`, recursively.
    ///
    /// Returns nil rather than an empty list when the directory is missing: a
    /// scan that passes because it found nothing to scan is worse than no scan
    /// at all, and the callers below record an issue on nil.
    static func files(under subpath: String) -> [URL]? {
        let dir = root.appendingPathComponent(subpath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append(url)
        }
        return out.isEmpty ? nil : out.sorted { $0.path < $1.path }
    }

    /// One source file with everything that is not code removed.
    ///
    /// Comments go because a comment explaining why a number is NOT here would
    /// otherwise read as the number being here. Localized copy goes for the
    /// same reason: `L.tr("다른 사용자와 비교하지 않으며", …)` is the promise,
    /// not the breach. String literals outside `L.tr` are kept — a limit table
    /// keyed by a tier name lives in exactly that position.
    static func code(of url: URL) -> [(line: Int, text: String)] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // Block comments first, keeping the newlines so line numbers survive.
        var stripped = ""
        var index = raw.startIndex
        while let open = raw.range(of: "/*", range: index..<raw.endIndex) {
            stripped += raw[index..<open.lowerBound]
            guard let close = raw.range(of: "*/", range: open.upperBound..<raw.endIndex) else {
                index = raw.endIndex
                break
            }
            stripped += raw[open.lowerBound..<close.upperBound].filter { $0 == "\n" }
            index = close.upperBound
        }
        stripped += raw[index...]

        return stripped.components(separatedBy: "\n").enumerated().map { offset, line in
            var text = line
            if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
            text = removeLocalizedCopy(text)
            return (offset + 1, text)
        }
    }

    /// Drop the arguments of every `L.tr(` on the line. Nested parentheses in
    /// interpolations are why this counts depth instead of matching a regex.
    private static func removeLocalizedCopy(_ line: String) -> String {
        guard line.contains("L.tr(") else { return line }
        var out = ""
        var rest = Substring(line)
        while let call = rest.range(of: "L.tr(") {
            out += rest[..<call.lowerBound] + "L.tr("
            var depth = 1
            var cursor = call.upperBound
            while cursor < rest.endIndex, depth > 0 {
                if rest[cursor] == "(" { depth += 1 }
                if rest[cursor] == ")" { depth -= 1 }
                cursor = rest.index(after: cursor)
            }
            out += ")"
            rest = rest[cursor...]
        }
        return out + rest
    }

    /// Every integer literal on a line, underscores removed.
    static func magnitudes(in text: String) -> [Int] {
        var out: [Int] = []
        var digits = ""
        var previous: Character = " "
        for character in text + " " {
            if character.isNumber || (character == "_" && !digits.isEmpty) {
                if digits.isEmpty && (previous.isLetter || previous == "_" || previous == ".") {
                    // Part of an identifier (`p95`, `seven_day`) or a decimal
                    // fraction, not a magnitude of its own.
                    previous = character
                    continue
                }
                digits.append(character)
            } else {
                if !digits.isEmpty, character != "." , !character.isLetter,
                   let value = Int(digits.replacingOccurrences(of: "_", with: "")) {
                    out.append(value)
                }
                digits = ""
            }
            previous = character
        }
        return out
    }
}

// MARK: - T069

@Suite("No tier limit is a number this app knows")
struct NoHardcodedTierLimitTests {

    /// Names a constant would have if it held the size of a limit.
    static let limitNaming = ["limit", "quota", "cap", "allowance", "budget", "ceiling", "tokens"]

    /// Suffixes that make a magnitude a DURATION rather than a limit size.
    /// A window is five hours long and that is a fact about the clock, not
    /// about how much of the plan it holds — this is the one exemption, and it
    /// is narrow on purpose.
    static let durationSuffixes = ["ms", "sec", "seconds", "minutes", "hours", "days", "ns", "interval"]

    /// Vocabulary a provider mints for a tier. Nothing in `Domain/` may pair
    /// one of these with a magnitude.
    static let tierVocabulary = [
        "max_5x", "max_20x", "max5x", "claude_max", "claude_pro",
        "codex_plus", "prolite", "\"pro\"", "\"free\"", "\"team\"",
        "\"enterprise\"", "\"max\"",
    ]

    /// Above this an integer stops being a count, an index or a percentage and
    /// starts being the kind of number a token limit is.
    static let magnitudeFloor = 1000

    @Test("no constant in Domain names itself a limit and holds a magnitude")
    func noLimitSizedConstants() throws {
        let files = try #require(SourceTree.files(under: "Domain"),
                                 "Domain sources not found at \(SourceTree.root.path) — this scan proves nothing without them")
        var findings: [String] = []
        for file in files {
            for (number, text) in SourceTree.code(of: file) {
                guard let name = declaredName(in: text) else { continue }
                let lowered = name.lowercased()
                guard Self.limitNaming.contains(where: { lowered.contains($0) }) else { continue }
                guard !Self.durationSuffixes.contains(where: { lowered.hasSuffix($0) }) else { continue }
                let big = SourceTree.magnitudes(in: text).filter { $0 >= Self.magnitudeFloor }
                if !big.isEmpty {
                    findings.append("\(file.lastPathComponent):\(number) — \(name) = \(big)")
                }
            }
        }
        #expect(findings.isEmpty,
                "constitution II forbids a tier's absolute limit in this app; found \(findings)")
        print("== T069 scanned \(files.count) Domain sources for limit-sized constants ==")
    }

    @Test("no tier name in Domain sits beside a magnitude")
    func noTierKeyedTables() throws {
        let files = try #require(SourceTree.files(under: "Domain"))
        var findings: [String] = []
        for file in files {
            let lines = SourceTree.code(of: file)
            for (index, entry) in lines.enumerated() {
                guard Self.tierVocabulary.contains(where: { entry.text.contains($0) }) else { continue }
                // A table spread over several lines still counts, so the
                // window is the tier name's neighbourhood, not its own line.
                let window = lines[max(0, index - 2)..<min(lines.count, index + 3)]
                let big = window.flatMap { SourceTree.magnitudes(in: $0.text) }.filter { $0 >= 100 }
                if !big.isEmpty {
                    findings.append("\(file.lastPathComponent):\(entry.line) — \(entry.text.trimmingCharacters(in: .whitespaces)) near \(big)")
                }
            }
        }
        #expect(findings.isEmpty,
                "a tier name next to a magnitude is a limit table; found \(findings)")
    }

    /// A declaration's identifier, or nil when the line declares nothing.
    private func declaredName(in text: String) -> String? {
        for keyword in ["let ", "var ", "case "] {
            guard let start = text.range(of: keyword) else { continue }
            let tail = text[start.upperBound...]
            let name = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            // Only a binding: `case .upgrade(let reason):` has no initialiser
            // and cannot hold a magnitude.
            guard !name.isEmpty, tail.contains("=") else { continue }
            return String(name)
        }
        return nil
    }
}

// MARK: - T077

@Suite("The plan-fit page compares the reader with nobody")
@MainActor
struct NoCohortComparisonTests {

    /// Identifiers and non-localized strings that would exist only if a cohort
    /// did.
    ///
    /// Two words are deliberately narrower than they look. `percentile` is
    /// absent entirely: percentiles of the reader's OWN windows are what the
    /// page is built on. And `peer` is matched only in compounds — the verdict
    /// layer's `peers:` parameter is the other SEGMENTS of the same account
    /// that share a limit, which is how a tier change is detected, and it has
    /// nothing to do with other people.
    static let cohortVocabulary = [
        "cohort", "benchmark", "leaderboard", "ranking",
        "peergroup", "peerrank", "peeraverage", "peercomparison", "peeruser",
        "otherusers", "averageuser", "communityaverage", "populationp",
        "또래", "동료 비교",
    ]

    @Test("no cohort vocabulary appears in the plan-fit code")
    func noCohortInSources() throws {
        let presentation = try #require(SourceTree.files(under: "Presentation/PlanFit"),
                                        "Presentation/PlanFit sources not found — this scan proves nothing without them")
        let domain = try #require(SourceTree.files(under: "Domain"))
        let planFitDomain = domain.filter {
            ["WindowStats.swift", "PlanFitVerdict.swift", "PeriodAggregation.swift",
             "AccountShape.swift"].contains($0.lastPathComponent)
        }
        var findings: [String] = []
        for file in presentation + planFitDomain {
            for (number, text) in SourceTree.code(of: file) {
                let lowered = text.lowercased()
                for term in Self.cohortVocabulary where lowered.contains(term.lowercased()) {
                    findings.append("\(file.lastPathComponent):\(number) — \(term)")
                }
            }
        }
        #expect(findings.isEmpty,
                "FR-050 / invariant 6: the page may not compare the reader with anyone; found \(findings)")
        print("== T077 scanned \(presentation.count + planFitDomain.count) sources for cohort vocabulary ==")
    }

    /// The other half: nothing the page can DRAW says it either.
    ///
    /// `PlanFitSnapshotTests.noPeerComparison` checks a handful of strings on
    /// the model; this walks every string the model can produce, in both
    /// languages, for every case in the matrix — including the sections added
    /// after that test was written.
    @Test("no string the page can draw ranks the reader against anyone",
          arguments: PlanFitSnapshotMatrix.all)
    func noCohortInRenderedText(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        let text = PlanFitModelText.every(of: model)
        #expect(!text.isEmpty, "\(snapshotCase.name) produced no text to audit")
        // "상위 " would appear in a percentile ranking; "다른 사용자" and
        // "other users" appear in the page's own promise NOT to compare, so
        // they are matched only when they are not preceded by the negation.
        let forbidden = ["상위 ", "percentile of users", "평균 사용자", "average user",
                         "compared with other", "다른 사용자보다", "또래"]
        for phrase in forbidden {
            let offenders = text.filter { $0.contains(phrase) }
            #expect(offenders.isEmpty, "\(snapshotCase.name) says \(phrase): \(offenders)")
        }
    }
}

// MARK: - T075 / T076

@Suite("Colour is never the only carrier, and the page never moves")
@MainActor
struct PlanFitColourAndMotionTests {

    // MARK: T075 — every varying colour has a varying shape or word beside it

    /// Enumerated rather than described: each of these is a place on the page
    /// where the colour changes with the meaning, and each has to change
    /// something else at the same time.
    @Test("every semantic tone brings a distinct symbol")
    func markTonesCarryShape() {
        let tones: [PlanFitMark.Tone] = [.neutral, .attention, .blocked]
        #expect(Set(tones.map(\.symbolName)).count == tones.count)
    }

    @Test("every provenance brings a distinct symbol and a distinct word")
    func provenanceCarriesShapeAndWord() {
        let all = Provenance.allCases
        #expect(Set(all.map(\.symbolName)).count == all.count)
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(all.allSatisfy { !$0.explanation.isEmpty })
    }

    /// An exhaustion's severity picks its tick colour AND its tick height, and
    /// every severity has a word for the row beside the strip.
    @Test("exhaustion severity changes the tick's height, not only its colour")
    func severityCarriesHeight() {
        let severities: [ActiveUseLimitModel.Severity] =
            [.interrupting, .partial, .harmless, .unknownTiming]
        #expect(Set(severities.map(\.label)).count == severities.count)
        // `harmless` and `unknownTiming` deliberately share a height: they are
        // both short marks, and they are told apart by the word, which is why
        // the label check above is the one that has to be exhaustive.
        #expect(ExhaustionTimingStrip.tickHeight(.interrupting)
                > ExhaustionTimingStrip.tickHeight(.partial))
        #expect(ExhaustionTimingStrip.tickHeight(.partial)
                > ExhaustionTimingStrip.tickHeight(.harmless))
    }

    /// A period still running is drawn hollow with a dashed edge, and it also
    /// carries a note in words. The note is what this can assert from the
    /// model; the dashed edge is asserted in pixels below.
    @Test("an unfinished period is named in words, not only drawn differently",
          arguments: PlanFitSnapshotMatrix.all)
    func incompletePeriodsCarryAWord(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        for bar in model.trend.bars where !bar.isComplete {
            #expect(bar.incompleteNote?.isEmpty == false,
                    "\(snapshotCase.name): an unfinished period is distinguished only by its outline")
        }
    }

    /// The pixel half of FR-058, and the only kind of proof that catches a
    /// hue-only distinction: strip the hue and the two marks must still differ.
    ///
    /// If `attention` and `blocked` were the same lightness in different hues,
    /// their luminance fields would be identical and a reader who cannot
    /// separate the hues would see one mark twice.
    @Test("two semantic marks stay different with the hue removed",
          arguments: PlanFitSnapshotTheme.allCases)
    func marksDifferInGreyscale(theme: PlanFitSnapshotTheme) throws {
        let size = CGSize(width: 220, height: 40)
        let same = L.tr("한도에 걸렸습니다", "the limit was reached")
        let attention = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitMark(tone: .attention, text: same), theme: theme, size: size))
        let blocked = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitMark(tone: .blocked, text: same), theme: theme, size: size))
        let neutral = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitMark(tone: .neutral, text: same), theme: theme, size: size))

        // The same words in all three, so anything that differs is the symbol
        // or the weight — never the hue, which greyscale has already removed.
        for (name, other) in [("blocked", blocked), ("neutral", neutral)] {
            let difference = PanelRaster.luminanceDifference(attention, other)
            #expect(difference > 0.001,
                    "attention and \(name) are identical once the hue is removed (\(difference)) in \(theme)")
        }
    }

    /// And the timing strip: a strip of early exhaustions must not look like a
    /// strip of harmless ones in greyscale either.
    @Test("the timing strip encodes severity in more than hue",
          arguments: PlanFitSnapshotTheme.allCases)
    func timingStripDiffersInGreyscale(theme: PlanFitSnapshotTheme) throws {
        let size = CGSize(width: 300, height: 60)
        func strip(_ severity: ActiveUseLimitModel.Severity) -> some View {
            ExhaustionTimingStrip(ticks: (0..<6).map { index in
                ActiveUseLimitModel.Tick(
                    id: Int64(index),
                    fractionLeft: 0.2 + Double(index) * 0.1,
                    severity: severity
                )
            })
        }
        let early = try #require(PlanFitSnapshotRenderer.raster(
            strip(.interrupting), theme: theme, size: size))
        let harmless = try #require(PlanFitSnapshotRenderer.raster(
            strip(.harmless), theme: theme, size: size))
        let difference = PanelRaster.luminanceDifference(early, harmless)
        #expect(difference > 0.001,
                "early and harmless exhaustions are identical without hue (\(difference)) in \(theme)")
    }

    // MARK: T076 — the page respects the system, because it never moves

    /// Reduce Motion is honoured structurally rather than by consulting it:
    /// **the page has no animation to reduce.** Nothing on it grows out of an
    /// axis, fades in or slides, so there is no state in which the setting
    /// would change what a reader sees.
    ///
    /// The scan is the guarantee. A `withAnimation` added later would make the
    /// page animate without anyone remembering that `Motion` exists, and this
    /// is what fails when that happens.
    @Test("no plan-fit source can animate")
    func planFitDoesNotAnimate() throws {
        let files = try #require(SourceTree.files(under: "Presentation/PlanFit"))
        var findings: [String] = []
        for file in files {
            for (number, text) in SourceTree.code(of: file) {
                for construct in ["withAnimation", ".animation(", ".transition(",
                                  "matchedGeometryEffect", "repeatForever"] {
                    if text.contains(construct) {
                        findings.append("\(file.lastPathComponent):\(number) — \(construct)")
                    }
                }
            }
        }
        #expect(findings.isEmpty,
                "FR-061: the page animates, so it must consult `Motion` / accessibilityReduceMotion; found \(findings)")
    }

    /// System appearance is honoured the same way: every colour on the page is
    /// dynamic. Nothing is a fixed sRGB triple except the two semantic tones,
    /// and those resolve through `NSAppearance.bestMatch` — which is exactly
    /// what makes them appearance-aware rather than what makes them fixed.
    @Test("no plan-fit source hardcodes a colour that cannot follow the appearance")
    func planFitColoursAreDynamic() throws {
        let files = try #require(SourceTree.files(under: "Presentation/PlanFit"))
        var findings: [String] = []
        for file in files {
            for (number, text) in SourceTree.code(of: file) {
                // `Color(nsColor: .init(name:))` is the appearance-resolving
                // form and is the one exemption; a bare literal is not.
                let appearanceResolved = text.contains("appearance.bestMatch")
                    || text.contains("srgbRed")
                for literal in ["Color.black", "Color.white", "Color(red:", "Color(white:",
                                "Color.red", "Color.orange", "Color.green", "Color.yellow"] {
                    if text.contains(literal), !appearanceResolved {
                        findings.append("\(file.lastPathComponent):\(number) — \(literal)")
                    }
                }
            }
        }
        #expect(findings.isEmpty,
                "FR-061: a fixed colour cannot follow the system appearance; found \(findings)")
    }

    /// And the render proof: light and dark are genuinely different pages, not
    /// one page with a tinted background.
    @Test("the two appearances produce different ink, not just different grounds")
    func appearancesDifferInInk() throws {
        let light = try #require(PlanFitSnapshotRenderer.render(
            PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .light)))
        let dark = try #require(PlanFitSnapshotRenderer.render(
            PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .dark)))
        // Both must carry readable text against their own ground; a page that
        // followed only the backdrop would fail on one of them.
        #expect(light.pagePeakContrast >= 4.5)
        #expect(dark.pagePeakContrast >= 4.5)
        #expect(PanelRaster.luminanceDifference(light, dark) > 0.5,
                "the two appearances are nearly the same render")
    }
}
