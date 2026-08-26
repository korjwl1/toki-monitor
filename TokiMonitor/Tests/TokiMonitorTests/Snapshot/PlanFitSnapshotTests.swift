import Testing
import Foundation
import SwiftUI
import AppKit
@testable import TokiMonitor

// MARK: - What the plan-fit page actually looks like
//
// Nobody reviewing this work can see the screen, so every claim about the page
// is made here against something a machine can check: rendered pixels for the
// claims that are about pixels, the model for the claims that are about what
// gets said, and the static type of the view tree for the claim that the
// period toggle is the only control.
//
// The screen that matters most is the withheld one. The real database held 21
// window rows at measurement time, so "not enough history to judge" is what
// almost every user meets first — and if that screen renders blank, the
// feature reads as broken no matter how good the sufficient case looks.

@Suite("Plan-fit page renders")
@MainActor
struct PlanFitSnapshotTests {

    // MARK: Nothing is blank

    /// Every combination in the matrix draws something.
    ///
    /// The threshold is deliberately low — this is not a claim about beauty,
    /// it is the claim that a reader who opens the page on day one, or on day
    /// eighteen, is not looking at an empty rectangle.
    @Test("every case in the matrix draws a page", arguments: PlanFitSnapshotMatrix.all)
    func everyCaseDraws(snapshotCase: PlanFitSnapshotCase) throws {
        let raster = try #require(PlanFitSnapshotRenderer.render(snapshotCase),
                                  "\(snapshotCase.name) did not render")
        #expect(raster.pageInkCoverage > 0.02,
                "\(snapshotCase.name) is nearly empty: ink \(raster.pageInkCoverage)")
    }

    /// The withheld screen carries as much as a screen with a real verdict.
    ///
    /// This is the regression that would hurt most: a page that decides it has
    /// nothing to say and shows a stub. A withheld verdict is a normal result
    /// with a reason, an availability statement and every observed fact still
    /// on screen, so its ink is in the same league as the sufficient case's.
    @Test("the withheld screen is a full page, not a stub", arguments: PlanFitSnapshotTheme.allCases)
    func withheldScreenIsFull(theme: PlanFitSnapshotTheme) throws {
        let withheld = PlanFitSnapshotCase(sufficiency: .underLookback, segments: .four, theme: theme)
        let sufficient = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: theme)
        let withheldRaster = try #require(PlanFitSnapshotRenderer.render(withheld))
        let sufficientRaster = try #require(PlanFitSnapshotRenderer.render(sufficient))

        #expect(withheldRaster.pageInkCoverage > 0.05,
                "the screen most users see is nearly empty: \(withheldRaster.pageInkCoverage)")
        #expect(withheldRaster.pageInkCoverage > sufficientRaster.pageInkCoverage * 0.6,
                "withheld draws \(withheldRaster.pageInkCoverage) against \(sufficientRaster.pageInkCoverage) — it has become a stub")
    }

    /// And it says why, and when it will change.
    @Test("the withheld screen names its reason and when a verdict becomes possible")
    func withheldScreenExplainsItself() {
        for sufficiency in [PlanFitDataSufficiency.fewDays, .underLookback] {
            let snapshotCase = PlanFitSnapshotCase(sufficiency: sufficiency, segments: .one, theme: .light)
            let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
            #expect(model.lede.kind == .withheld, "\(snapshotCase.name)")
            #expect(!model.lede.headline.isEmpty)
            #expect(model.lede.availability?.isEmpty == false,
                    "\(snapshotCase.name) withholds without saying when that changes")
            // Withholding a verdict does not withhold the facts.
            #expect(model.hasSegments, "\(snapshotCase.name) dropped the observed limits too")
        }
    }

    /// Day one is guidance, not an error and not a chart of zeroes.
    @Test("the zero-row screen explains itself", arguments: PlanFitSnapshotTheme.allCases)
    func zeroRowScreen(theme: PlanFitSnapshotTheme) throws {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .noRows, segments: .one, theme: theme)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        #expect(model.lede.kind == .noData)
        #expect(model.lede.detail?.isEmpty == false)
        #expect(model.trend.isEmpty, "an empty account must not get a chart of zeroes")
        let raster = try #require(PlanFitSnapshotRenderer.render(snapshotCase))
        #expect(raster.pageInkCoverage > 0.02, "day one renders blank: \(raster.pageInkCoverage)")
    }

    // MARK: Contrast, both themes

    /// Body text clears WCAG AA against the ground it is drawn on, and there
    /// is enough of it that the peak is text rather than one stray border.
    @Test("both themes carry readable text", arguments: PlanFitSnapshotMatrix.all)
    func contrast(snapshotCase: PlanFitSnapshotCase) throws {
        let raster = try #require(PlanFitSnapshotRenderer.render(snapshotCase))
        #expect(raster.pagePeakContrast >= 4.5,
                "\(snapshotCase.name) peaks at \(raster.pagePeakContrast):1 — no readable body text")
        let readable = raster.pagePixelsAbove(contrast: 4.5)
        #expect(readable > 200,
                "\(snapshotCase.name) has only \(readable) sampled pixels at AA — the page is drawn but not readable")
    }

    /// The two appearances are genuinely different renders, not one appearance
    /// captured twice — the failure mode `PanelSnapshotHarness` documents.
    @Test("light and dark are different renders")
    func themesDiffer() throws {
        for sufficiency in PlanFitDataSufficiency.allCases {
            let light = try #require(PlanFitSnapshotRenderer.render(
                PlanFitSnapshotCase(sufficiency: sufficiency, segments: .four, theme: .light)))
            let dark = try #require(PlanFitSnapshotRenderer.render(
                PlanFitSnapshotCase(sufficiency: sufficiency, segments: .four, theme: .dark)))
            #expect(PanelRaster.difference(light, dark) > 0.5,
                    "\(sufficiency.rawValue): the two themes render the same pixels")
        }
    }

    // MARK: Layout at the window minimum

    /// Eight segments at 800pt do not push content off the edge.
    ///
    /// The page pads itself by `DS.lg`; content that does not fit is clipped by
    /// the scroll view at the boundary, which leaves cut glyphs and card edges
    /// in the outermost pixels. Finding none there is what "no horizontal
    /// overflow" can mean to a pixel test (FR-056).
    @Test("the layout holds at 800pt for every segment count",
          arguments: PlanFitSegmentCount.allCases, PlanFitSnapshotTheme.allCases)
    func noHorizontalOverflow(segments: PlanFitSegmentCount, theme: PlanFitSnapshotTheme) throws {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: segments, theme: theme)
        let raster = try #require(PlanFitSnapshotRenderer.render(snapshotCase))
        // 8 device pixels = 4pt, comfortably inside the 16pt page padding.
        #expect(raster.edgeInk(margin: 8) == 0,
                "\(snapshotCase.name) paints into its own margin — content is overflowing 800pt")
    }

    /// The screen with a real verdict on it, in pixels.
    ///
    /// The matrix fixtures are all short of the 28-day gate by construction, so
    /// without this the *rendered* evidence would only ever cover withholding.
    /// Account A is the heavy user whose overall numbers look relaxed: it
    /// reaches a verdict, and the verdict is an upgrade.
    @Test("the screen that carries a real verdict renders too",
          arguments: PlanFitSnapshotTheme.allCases)
    func verdictScreenRenders(theme: PlanFitSnapshotTheme) throws {
        let model = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        #expect(model.lede.kind == .considerUpgrade)
        let raster = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitContent(model: model, unit: .constant(.weekly)),
            theme: theme,
            size: CGSize(width: PlanFitSnapshotRenderer.width,
                         height: PlanFitSnapshotRenderer.height)
        ))
        #expect(raster.pageInkCoverage > 0.05, "the verdict screen is nearly empty")
        #expect(raster.pagePeakContrast >= 4.5)
        #expect(raster.edgeInk(margin: 8) == 0)
    }

    /// Monthly mode renders too. It is the mode with the fewest buckets over a
    /// 28-day lookback, so it is the one most likely to degenerate.
    @Test("monthly mode renders at every segment count", arguments: PlanFitSegmentCount.allCases)
    func monthlyModeRenders(segments: PlanFitSegmentCount) throws {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: segments, theme: .light)
        let raster = try #require(PlanFitSnapshotRenderer.render(snapshotCase, unit: .monthly))
        #expect(raster.pageInkCoverage > 0.05)
        #expect(raster.edgeInk(margin: 8) == 0)
    }
}

// MARK: - Hierarchy

@Suite("Plan-fit visual hierarchy")
@MainActor
struct PlanFitHierarchyTests {

    /// T049 / FR-055. The old page drew the verdict at `DS.fontCaption` (10pt)
    /// and its supporting statistics at `DS.fontBody` (12pt) — the conclusion
    /// was literally the smallest thing on screen. The design reference asks
    /// for at least a 1.5x step between hierarchy levels.
    @Test("the conclusion outranks every supporting number")
    func ledeOutranksMetrics() {
        #expect(PlanFitType.ledeToMetricRatio >= 1.5,
                "lede \(PlanFitType.lede)pt against metric \(PlanFitType.metric)pt is \(PlanFitType.ledeToMetricRatio)x — under the 1.5x step")
        #expect(PlanFitType.ledeToBodyRatio >= 2.0)
        // And nothing else on the page is allowed to reach it.
        let others = [
            PlanFitType.metric, PlanFitType.sectionTitle,
            PlanFitType.body, PlanFitType.caption, PlanFitType.tiny,
        ]
        #expect(others.allSatisfy { $0 < PlanFitType.lede })
        #expect(PlanFitType.lede > DS.fontTitle,
                "the page's conclusion must outrank a panel title")
    }

    /// The lede is never absent. Every state of the page — including the ones
    /// where there is nothing to conclude — leads with a sentence.
    @Test("every state leads with a sentence", arguments: PlanFitSnapshotMatrix.all)
    func everyStateHasALede(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        #expect(!model.lede.headline.isEmpty, "\(snapshotCase.name) has no conclusion at the top")
    }

    /// The three surfaces differ in more than fill, so the ordering survives a
    /// render that loses colour.
    @Test("surfaces are distinguishable without colour")
    func surfacesDifferStructurally() {
        #expect(PlanFitSurface.lede.padding > PlanFitSurface.section.padding)
        #expect(PlanFitSurface.section.padding > PlanFitSurface.inner.padding)
        #expect(PlanFitSurface.lede.radius > PlanFitSurface.section.radius)
        #expect(PlanFitSurface.section.radius > PlanFitSurface.inner.radius)
    }
}

// MARK: - The control surface

@Suite("Plan-fit control surface")
@MainActor
struct PlanFitControlSurfaceTests {

    /// Interactive constructs whose presence anywhere in the view tree shows
    /// up in the static type of `body`.
    static let forbidden = [
        "Button", "Menu", "NavigationLink", "TextField", "TextEditor",
        "Toggle", "Stepper", "Slider", "ColorPicker", "DatePicker",
        "ContextMenu", "Gesture", "Popover", "Sheet", "Alert",
    ]

    private func contentBodyType(_ unit: PeriodUnit = .weekly) -> String {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .light)
        let content = PlanFitContent(
            model: PlanFitSnapshotRenderer.model(for: snapshotCase, unit: unit),
            unit: .constant(unit)
        )
        return String(describing: type(of: content.body))
    }

    /// FR-001 / T043. The period toggle is the only control, and the page
    /// cannot express another one: SwiftUI encodes the whole static view tree
    /// in the type of `body`, so a Button added anywhere under `PlanFitContent`
    /// changes that type and fails here. This is what "no path into an editor"
    /// means as something a test can hold.
    @Test("the period toggle is the only control the page can express")
    func onlyControlIsThePeriodToggle() {
        let body = contentBodyType()
        #expect(body.contains("Picker"), "the period toggle is not in the view tree")
        for construct in Self.forbidden {
            #expect(!body.contains(construct),
                    "`\(construct)` appears in the plan-fit view tree — the page has grown a second control")
        }
    }

    /// The same holds in both period modes: neither branch of the layout hides
    /// a control the other does not have.
    @Test("neither period mode introduces a control", arguments: PeriodUnit.allCases)
    func bothModesAreControlFree(unit: PeriodUnit) {
        let body = contentBodyType(unit)
        for construct in Self.forbidden {
            #expect(!body.contains(construct), "`\(construct)` appears in \(unit.rawValue) mode")
        }
    }

    /// `PlanFitContent` holds exactly one binding and it is the period unit.
    /// Everything else it has is a value.
    @Test("the page owns exactly one piece of writable state")
    func exactlyOneBinding() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .light)
        let content = PlanFitContent(
            model: PlanFitSnapshotRenderer.model(for: snapshotCase),
            unit: .constant(.weekly)
        )
        let bindings = Mirror(reflecting: content).children.filter {
            String(describing: type(of: $0.value)).hasPrefix("Binding<")
        }
        #expect(bindings.count == 1, "expected one binding, found \(bindings.count)")
        let bindingType = bindings.first.map { String(describing: type(of: $0.value)) } ?? ""
        #expect(bindingType.contains("PeriodUnit"), "the one binding is \(bindingType)")
    }

    /// Sections are projections. No bindings, no closures, no state of their
    /// own — so there is nothing for an editor entry point to be attached to.
    @Test("no section holds a binding, a closure or state")
    func sectionsAreProjections() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        let sections: [(String, Any)] = [
            ("VerdictSection", VerdictSection(lede: model.lede, others: model.otherVerdicts)),
            ("PeriodTrendSection", PeriodTrendSection(model: model.trend)),
            ("LimitStatusSection", LimitStatusSection(groups: model.limitGroups)),
            ("ActiveUseSection", ActiveUseSection(limits: model.activeUse,
                                                  quietLimitsNote: model.quietLimitsNote)),
            ("ProviderComparisonSection", ProviderComparisonSection(model: model.comparison)),
            ("ModelPatternSection", ModelPatternSection(model: model.modelPattern)),
            ("EmptyStateSection", EmptyStateSection(model: model.readiness)),
            ("MoneyFootnote", MoneyFootnote(model: model.money)),
            ("SubscriptionComparisonSection",
             SubscriptionComparisonSection(model: model.subscriptionComparison)),
        ]
        for (name, section) in sections {
            for child in Mirror(reflecting: section).children {
                let type = String(describing: type(of: child.value))
                #expect(!type.hasPrefix("Binding<"), "\(name).\(child.label ?? "?") is a binding")
                #expect(!type.hasPrefix("State<"), "\(name).\(child.label ?? "?") is state")
                #expect(!type.contains(" -> "), "\(name).\(child.label ?? "?") is a closure")
            }
        }
    }

    /// FR-006 / T044. The choice is stored, and it is stored as a stable
    /// string — a raw value that drifts would silently reset everyone's page.
    @Test("the period choice is persisted under a stable key")
    func periodChoicePersists() {
        let page = PlanFitPage(reportClient: TokiReportClient())
        let stored = Mirror(reflecting: page).children.filter {
            String(describing: type(of: $0.value)).hasPrefix("AppStorage<")
        }
        #expect(stored.count == 1, "expected exactly one persisted setting, found \(stored.count)")
        let storedType = stored.first.map { String(describing: type(of: $0.value)) } ?? ""
        #expect(storedType.contains("PeriodUnit"), "the persisted setting is \(storedType)")

        // The raw values `AppStorage` writes, round-tripped through a scratch
        // store rather than the user's own defaults.
        let suite = "planfit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for unit in PeriodUnit.allCases {
            defaults?.set(unit.rawValue, forKey: "planFit.periodUnit")
            let read = defaults?.string(forKey: "planFit.periodUnit").flatMap(PeriodUnit.init(rawValue:))
            #expect(read == unit, "\(unit.rawValue) did not survive the store")
        }
    }
}

// MARK: - What the page says

@Suite("Plan-fit honesty on screen")
@MainActor
struct PlanFitHonestyTests {

    /// T051 / contract V8. Slack and the sentence that stops it being read as
    /// a guarantee arrive together, on every screen, everywhere either can
    /// appear. The type makes it unrepresentable; this checks the type is the
    /// one actually being rendered from.
    @Test("headroom is never stated without the caveat", arguments: PlanFitSnapshotMatrix.all)
    func headroomAlwaysCarriesItsCaveat(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        var notes: [HeadroomNote] = []
        if let lede = model.lede.headroom { notes.append(lede) }
        notes += model.limitGroups.flatMap(\.limits).compactMap(\.headroom)
        for note in notes {
            #expect(!note.sensitivity.isEmpty)
            #expect(!note.caveat.isEmpty, "\(snapshotCase.name): a sensitivity with no caveat")
            #expect(note.caveat.contains(L.tr("보증", "guarantee")),
                    "\(snapshotCase.name): the caveat no longer says what it is for")
        }
    }

    /// The account whose overall numbers look relaxed and whose worked windows
    /// do not. The failure mode this feature exists to prevent has to reach the
    /// screen, not just the domain: A leads with an upgrade, B does not.
    @Test("the page's lede separates account A from account B")
    func ledeSeparatesTheTwoAccounts() {
        let a = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        let b = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountB(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        #expect(a.lede.kind == .considerUpgrade,
                "account A leads with \(a.lede.kind.rawValue) — the whole-average reading has come back")
        #expect(b.lede.kind != .considerUpgrade,
                "account B leads with an upgrade, but its exhaustions were all minutes before a reset")
        #expect(a.lede.headline != b.lede.headline)
    }

    /// T048. Every exhaustion is placed by how much of the cycle it left, and
    /// account A — which ran out early, repeatedly — says so on screen.
    @Test("exhaustions reach the screen with the time they left on the clock")
    func exhaustionsCarryTheirTiming() {
        let model = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        let limit = try? #require(model.activeUse.first)
        guard let limit else { return }
        #expect(limit.ticks.count == 20, "20 exhaustions, \(limit.ticks.count) placed")
        #expect(limit.ticks.allSatisfy { $0.fractionLeft != nil })
        #expect(limit.ticks.allSatisfy { $0.severity == .interrupting },
                "A ran out with most of the cycle left every time")
        #expect(limit.medianTimeLeftText?.isEmpty == false)
        #expect(!limit.recentEvents.isEmpty)
        #expect(limit.recentEvents.allSatisfy { !$0.text.isEmpty })
        // The thresholds that produced the split are on screen with it.
        #expect(limit.thresholdNote.contains("\(Int(WindowStats.harmlessExhaustionFractionLeft * 100))"))
    }

    /// Account B's exhaustions are the mirror image: just as many, none of them
    /// an interruption.
    @Test("an account that tops out at the reset reads differently")
    func harmlessExhaustionsReadAsHarmless() {
        let model = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountB(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        let limit = try? #require(model.activeUse.first)
        guard let limit else { return }
        #expect(limit.ticks.count == 25)
        #expect(limit.ticks.allSatisfy { $0.severity == .harmless })
    }

    /// T052 / FR-049. The trend is a sum of `activeMs`, which restarts with the
    /// daemon, so it is tagged as a floor and never as an observation.
    @Test("the recorded-work trend is presented as a lower bound", arguments: PeriodUnit.allCases)
    func trendIsALowerBound(unit: PeriodUnit) {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .one, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase, unit: unit)
        #expect(model.trend.provenance == .lowerBound)
        #expect(!model.trend.isEmpty)
    }

    /// T052. A censored percentile is a floor on demand, not a measurement of
    /// it, and the tag on screen says which one the reader is looking at.
    @Test("a censored distribution is tagged as a floor")
    func censoredDistributionIsTagged() {
        let model = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        let limits = model.limitGroups.flatMap(\.limits)
        let censored = limits.filter(\.meterIsCensored)
        #expect(!censored.isEmpty, "account A's worked windows hit the limit; nothing is censored")
        #expect(censored.allSatisfy { $0.distributionProvenance == .lowerBound })
        #expect(censored.allSatisfy { $0.distribution.contains("≥") },
                "a clipped percentile printed as an exact figure")
    }

    /// FR-003. Switching the unit re-partitions the same samples; it does not
    /// change how much usage the page reports.
    @Test("the unit switch preserves the total")
    func unitSwitchPreservesTotal() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .four, theme: .light)
        let rows = PlanFitSnapshotMatrix.rows(for: snapshotCase)
        let weekly = PlanFitModelBuilder.build(rows: rows, unit: .weekly, nowMs: PlanFitSnapshotMatrix.nowMs)
        let monthly = PlanFitModelBuilder.build(rows: rows, unit: .monthly, nowMs: PlanFitSnapshotMatrix.nowMs)
        #expect(abs(weekly.trend.totalHours - monthly.trend.totalHours) < 0.001,
                "weekly totals \(weekly.trend.totalHours)h, monthly \(monthly.trend.totalHours)h")
        #expect(weekly.trend.bars.count != monthly.trend.bars.count,
                "the two units produced the same buckets — the switch did nothing")
    }

    /// FR-004. An unfinished period is marked, and its comparison against the
    /// previous one is the length-neutral one — an in-progress total held
    /// against a finished total reports a collapse that is only the calendar.
    @Test("an unfinished period is marked and compared on its daily average")
    func incompletePeriodIsDistinct() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .one, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase, unit: .monthly)
        guard let current = model.trend.bars.last else {
            Issue.record("no periods at all")
            return
        }
        if !current.isComplete {
            #expect(current.incompleteNote?.isEmpty == false,
                    "an in-progress period renders exactly like a finished one")
            #expect(current.changeIsDailyAverage || current.changeRatePct == nil,
                    "an in-progress period is being compared on its absolute total")
        }
        #expect(model.trend.bars.allSatisfy { $0.isComplete == ($0.incompleteNote == nil) },
                "the in-progress marker and the flag disagree")
    }

    /// FR-007 / T046. Every monthly bucket carries its own daily rate, not
    /// just the one the readout spells out — months are 28 to 31 days long, so
    /// two absolute totals side by side are not a comparison.
    @Test("monthly mode gives every period a daily average")
    func monthlyPeriodsCarryTheirDailyAverage() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .one, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase, unit: .monthly)
        #expect(!model.trend.bars.isEmpty)
        for bar in model.trend.bars {
            // nil is allowed only under one observed day, where a daily rate
            // would be one morning's work multiplied up.
            if bar.dailyAverageHours == nil {
                #expect(!bar.isComplete, "a finished month with no daily average: \(bar.label)")
            }
        }
        let complete = model.trend.bars.filter(\.isComplete)
        #expect(complete.allSatisfy { $0.dailyAverageHours != nil })
    }

    /// FR-050 / invariant 6. No cohort, no peer ranking, anywhere on the page.
    @Test("nothing on the page compares the user with anyone else",
          arguments: PlanFitSnapshotMatrix.all)
    func noPeerComparison(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        var text = [model.lede.headline, model.lede.detail ?? "", model.trend.spanNote]
        text += model.limitGroups.flatMap(\.limits).flatMap {
            [$0.distribution, $0.exhaustionText, $0.sampleText]
        }
        // Percentiles of the user's OWN windows are the point; percentiles
        // against other users are the thing that must not exist.
        for phrase in ["다른 사용자", "other users", "상위 ", "percentile of users", "평균 사용자"] {
            #expect(!text.contains { $0.contains(phrase) },
                    "\(snapshotCase.name) mentions \(phrase)")
        }
    }
}

// MARK: - The verdict section (T053)

@Suite("Plan-fit verdicts on screen")
@MainActor
struct PlanFitVerdictSectionTests {

    /// Every limit reaches the screen with a verdict of its own.
    ///
    /// A page with eight limits used to carry one conclusion and seven silences:
    /// the lede spoke for the segment that ranked highest and the rest appeared
    /// only as distributions. "Four limits fit and one interrupts you" is a
    /// different account from "five limits fit", so the other seven are rows.
    @Test("every limit's verdict reaches the screen", arguments: PlanFitSegmentCount.allCases)
    func everySegmentHasAVerdict(segments: PlanFitSegmentCount) {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: segments, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        #expect(model.otherVerdicts.count == segments.rawValue - 1,
                "\(segments.rawValue) limits produced \(model.otherVerdicts.count + 1) verdicts")
        // The lede's own segment is not repeated underneath it.
        #expect(Set(model.otherVerdicts.map(\.id)).count == model.otherVerdicts.count)
    }

    /// Contract V1. A withheld verdict is a full statement — its reason, and
    /// when it stops being withheld — on the rows as much as on the lede.
    @Test("a withheld row says why and when that changes")
    func withheldRowsCarryTheirAvailability() {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .underLookback, segments: .eight, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        let withheld = model.otherVerdicts.filter { $0.kind == .withheld }
        #expect(!withheld.isEmpty, "the under-lookback fixture reached a verdict on every limit")
        for row in withheld {
            #expect(!row.headline.isEmpty)
            #expect(row.availability?.isEmpty == false, "\(row.scope) withholds without saying when that changes")
            #expect(row.headroom == nil, "\(row.scope) states headroom while withholding")
            #expect(!row.basis.isEmpty, "\(row.scope) has no basis")
        }
    }

    /// Contract V3 / T032. Basis on every row, withheld included — a verdict
    /// with no lookback, no sample size and no statistic beside it is an
    /// assertion rather than a reading.
    @Test("every verdict row carries its basis", arguments: PlanFitDataSufficiency.allCases)
    func everyRowCarriesItsBasis(sufficiency: PlanFitDataSufficiency) {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: sufficiency, segments: .eight, theme: .light)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        for row in model.otherVerdicts {
            #expect(!row.basis.isEmpty, "\(row.scope)")
            #expect(!row.scope.isEmpty)
        }
    }

    /// Contract V8, on the rows as well as the lede: slack and the sentence
    /// that stops it reading as a guarantee are one value.
    @Test("no verdict row states headroom without its caveat",
          arguments: PlanFitSnapshotMatrix.all)
    func rowHeadroomCarriesItsCaveat(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        for row in model.otherVerdicts {
            guard let headroom = row.headroom else { continue }
            #expect(!headroom.sensitivity.isEmpty)
            #expect(headroom.caveat.contains(L.tr("보증", "guarantee")),
                    "\(row.scope): headroom without the V8 caveat")
        }
    }

    /// Contract V7. There is no tier catalogue and no price feed for
    /// subscriptions, so a verdict naming either could only have invented it.
    /// The verdict speaks about *the current plan*.
    @Test("no verdict names a tier or a price", arguments: PlanFitSnapshotMatrix.all)
    func verdictsNameNoTierOrPrice(snapshotCase: PlanFitSnapshotCase) {
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        var text = [model.lede.headline, model.lede.availability ?? "", model.lede.detail ?? ""]
        if let headroom = model.lede.headroom { text += [headroom.sensitivity, headroom.caveat] }
        for row in model.otherVerdicts {
            text += [row.headline, row.availability ?? "", row.basis]
            if let headroom = row.headroom { text += [headroom.sensitivity, headroom.caveat] }
        }
        // A currency mark, a monthly rate, or a tier name from the provider's
        // own ladder. None of the three is knowable from window rows.
        for phrase in ["$", "₩", "USD", "/mo", "월 요금", "20x", "5x 요금제", "Pro 요금제", "Max 요금제"] {
            #expect(!text.contains { $0.contains(phrase) },
                    "\(snapshotCase.name): a verdict says \(phrase)")
        }
    }

    /// The verdict rows rank the same way the lede was elected, so a reader
    /// scanning down meets the limits with something to say before the ones
    /// still collecting.
    @Test("verdict rows lead with the limits that have something to say")
    func rowsAreRankedNotArbitrary() {
        let model = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA() + PlanFitSnapshotMatrix.rows(
                for: PlanFitSnapshotCase(sufficiency: .fewDays, segments: .four, theme: .light)
            ),
            unit: .weekly,
            nowMs: WindowFixtures.nowMs
        )
        let ranks = model.otherVerdicts.map { row -> Int in
            switch row.kind {
            case .considerUpgrade: return 0
            case .considerDowngrade: return 1
            case .fits: return 2
            default: return 3
            }
        }
        #expect(ranks == ranks.sorted(), "verdict rows are not ordered by what they have to say")
    }

    /// The whole verdict block renders, in both themes, without spilling out
    /// of 800pt — eight limits is eight verdicts.
    @Test("the verdict block renders at eight limits", arguments: PlanFitSnapshotTheme.allCases)
    func verdictBlockRenders(theme: PlanFitSnapshotTheme) throws {
        let snapshotCase = PlanFitSnapshotCase(sufficiency: .sufficient, segments: .eight, theme: theme)
        let model = PlanFitSnapshotRenderer.model(for: snapshotCase)
        let raster = try #require(PlanFitSnapshotRenderer.raster(
            VerdictSection(lede: model.lede, others: model.otherVerdicts),
            theme: theme,
            size: CGSize(width: PlanFitSnapshotRenderer.width, height: 1600)
        ))
        #expect(raster.pageInkCoverage > 0.03, "the verdict block is nearly empty")
        #expect(raster.pagePeakContrast >= 4.5)
    }
}

// MARK: - Provider comparison (T054, T055)

@Suite("Plan-fit provider comparison")
@MainActor
struct PlanFitProviderComparisonTests {

    private func comparison(_ rows: [(provider: String, row: WindowRow)]) -> ProviderComparisonModel {
        PlanFitModelBuilder.build(rows: rows, unit: .weekly, nowMs: WindowFixtures.nowMs).comparison
    }

    /// FR-024 / contract W2. The two histories start at different times —
    /// Codex is recovered from rollout files, Claude exists only from when
    /// polling began — so a comparison that does not name the period it used
    /// is crediting one provider with weeks the other was never watched for.
    @Test("the comparison names the common period it used")
    func commonPeriodIsStated() {
        let model = comparison(WindowFixtures.twoProviders())
        #expect(model.state == .comparable)
        let note = try? #require(model.commonPeriodNote)
        #expect(note?.isEmpty == false, "the comparison does not say what period it compared over")
        #expect(model.sides.count == 2)
    }

    /// And the windows outside it are named rather than silently dropped.
    @Test("windows outside the common period are declared, not dropped")
    func excludedWindowsAreDeclared() {
        let model = comparison(WindowFixtures.twoProviders())
        let codex = model.sides.first { $0.id == "codex" }
        #expect(codex?.excludedNote?.isEmpty == false,
                "Codex has 17 days Claude was never observed for, and the column does not say so")
        // Every side states its own span and how that history was collected.
        for side in model.sides {
            #expect(!side.historySpan.isEmpty)
            #expect(!side.collectionNote.isEmpty, "\(side.id) does not say how its history was collected")
        }
        let claude = model.sides.first { $0.id == "claude_code" }
        #expect(claude?.collectionNote != codex?.collectionNote,
                "both providers claim the same collection method")
    }

    /// FR-023. Utilisation percentages are relative to each provider's own
    /// undisclosed limit, so they never share an axis. What is compared is time
    /// and counts.
    @Test("no percentage is put on a shared axis")
    func noSharedUtilisationAxis() {
        let model = comparison(WindowFixtures.twoProviders())
        #expect(!model.incomparableNote.isEmpty)
        for side in model.sides {
            for metric in side.metrics {
                #expect(!metric.value.contains("%"),
                        "\(side.id) compares \(metric.label) as a percentage — the denominators differ")
            }
            // The limit system is described, not measured.
            #expect(!side.limitSystem.isEmpty)
        }
        // Both sides offer the same axes, or they are not being compared.
        let labels = model.sides.map { $0.metrics.map(\.label) }
        #expect(labels.dropFirst().allSatisfy { $0 == labels.first })
    }

    /// T055. One provider is a readout, not a comparison — and the empty side
    /// is explained, because polling switched off looks exactly like a provider
    /// that is not being used.
    @Test("one provider collapses to a single readout that explains the gap")
    func singleProviderCollapses() {
        let model = comparison(WindowFixtures.accountA())
        #expect(model.state == .singleProvider)
        #expect(model.sides.count == 1)
        #expect(model.commonPeriodNote == nil, "a single provider has no common period to state")
        let note = model.unavailableNote ?? ""
        #expect(!note.isEmpty, "the empty side is not explained")
        #expect(note.contains(PlanFitFormat.providerTitle("codex")),
                "the missing provider is not named: \(note)")
    }

    /// Two providers that were never observed at the same time. Inventing an
    /// overlap for them would compare different months.
    @Test("disjoint histories are reported as having nothing to compare")
    func disjointHistories() {
        let model = comparison(WindowFixtures.disjointProviders())
        #expect(model.state == .noOverlap)
        #expect(model.commonPeriodNote == nil)
        #expect(model.unavailableNote?.isEmpty == false)
    }

    @Test("an account with no windows has no comparison to draw")
    func noRowsNoComparison() {
        #expect(comparison([]).state == .none)
        #expect(comparison([]).isPresentable == false)
    }

    /// The section renders in both themes and holds 800pt.
    @Test("the comparison renders in both themes", arguments: PlanFitSnapshotTheme.allCases)
    func comparisonRenders(theme: PlanFitSnapshotTheme) throws {
        for rows in [WindowFixtures.twoProviders(),
                     WindowFixtures.accountA(),
                     WindowFixtures.disjointProviders()] {
            let model = PlanFitModelBuilder.build(rows: rows, unit: .weekly, nowMs: WindowFixtures.nowMs)
            let raster = try #require(PlanFitSnapshotRenderer.raster(
                PlanFitContent(model: model, unit: .constant(.weekly)),
                theme: theme,
                size: CGSize(width: PlanFitSnapshotRenderer.width, height: 2400)
            ))
            #expect(raster.pageInkCoverage > 0.03)
            #expect(raster.pagePeakContrast >= 4.5)
            #expect(raster.edgeInk(margin: 8) == 0, "the comparison overflows 800pt")
        }
    }
}

// MARK: - Recorded work time is not counted twice

@Suite("Plan-fit work time")
@MainActor
struct PlanFitWorkTimeTests {

    /// A provider reports overlapping window series — Claude's five-hour
    /// windows sit inside its weekly ones, and each of them accumulates its own
    /// `activeMs` over the same work. Summing every row reports the same
    /// afternoon once per limit the account happens to have, so the total grows
    /// when a provider adds a limit rather than when the user works more.
    @Test("overlapping limit series do not each contribute the same hours")
    func overlappingSeriesAreNotSummedTwice() {
        let fiveHour = (0..<8).map { i in
            WindowFixtures.window(
                kind: "session", limitId: "five_hour", endOffsetDays: Double(i) * 3,
                peakPct: 50, activeMs: 3_600_000
            )
        }
        // One weekly window covering the same days, carrying the same work.
        let weekly = [WindowFixtures.window(
            kind: "weekly", limitId: "seven_day", endOffsetDays: 1,
            peakPct: 50, activeMs: 8 * 3_600_000
        )]
        let sessionOnly = PlanFitModelBuilder.build(
            rows: fiveHour, unit: .weekly, nowMs: WindowFixtures.nowMs
        ).trend.totalHours
        let both = PlanFitModelBuilder.build(
            rows: fiveHour + weekly, unit: .weekly, nowMs: WindowFixtures.nowMs
        ).trend.totalHours
        #expect(abs(both - sessionOnly) < 0.001,
                "adding the weekly limit added \(both - sessionOnly)h of work the user never did")
    }

    /// Running out of the weekly limit and running out of the five-hour limit
    /// are two separate times the user was stopped, so exhaustions are still
    /// counted across every series.
    @Test("exhaustions are still counted on every limit")
    func exhaustionsCountAcrossSeries() {
        let rows = [
            WindowFixtures.window(kind: "session", limitId: "five_hour", endOffsetDays: 1,
                                  peakPct: 100, activeMs: 3_600_000, maxedOut: true,
                                  timeLeftFractionAtExhaustion: 0.5),
            WindowFixtures.window(kind: "weekly", limitId: "seven_day", endOffsetDays: 1,
                                  peakPct: 100, activeMs: 3_600_000, maxedOut: true,
                                  timeLeftFractionAtExhaustion: 0.5),
        ]
        let model = PlanFitModelBuilder.build(rows: rows, unit: .weekly, nowMs: WindowFixtures.nowMs)
        #expect(model.trend.bars.reduce(0) { $0 + $1.exhaustions } == 2,
                "one of the two limits running out went uncounted")
    }
}

// MARK: - Model patterns (T056, T057)

@Suite("Plan-fit model patterns")
@MainActor
struct PlanFitModelPatternTests {

    /// Claude reports model-scoped weekly limits; Codex reports one limit for
    /// everything. Token events exist for both.
    private func rows() -> [(provider: String, row: WindowRow)] {
        var rows: [(provider: String, row: WindowRow)] = []
        for i in 0..<4 {
            rows.append(WindowFixtures.window(
                provider: "claude_code", kind: "weekly", limitId: "seven_day_opus",
                endOffsetDays: Double(i) * 6, peakPct: Double(60 + i * 10),
                activeMs: 6 * 3_600_000, plan: "max_5x", account: "a"
            ))
            rows.append(WindowFixtures.window(
                provider: "claude_code", kind: "weekly", limitId: "seven_day_sonnet",
                endOffsetDays: Double(i) * 6, peakPct: Double(20 + i * 5),
                activeMs: 6 * 3_600_000, plan: "max_5x", account: "a"
            ))
            rows.append(WindowFixtures.window(
                provider: "codex", kind: "session", limitId: "codex",
                endOffsetDays: Double(i) * 6, peakPct: Double(40 + i * 5),
                activeMs: 4 * 3_600_000, plan: "codex_plus", account: "c"
            ))
        }
        return rows
    }

    private func samples() -> [ModelUsageSample] {
        let now = Date(timeIntervalSince1970: Double(WindowFixtures.nowMs) / 1000)
        var out: [ModelUsageSample] = []
        for day in 0..<20 {
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            out.append(.init(provider: "claude_code", model: "claude-opus-4-5", day: date,
                             totalTokens: 900_000 - Double(day) * 10_000, costUsd: 4.2))
            out.append(.init(provider: "claude_code", model: "claude-sonnet-4-5", day: date,
                             totalTokens: 300_000, costUsd: 0.9))
            out.append(.init(provider: "codex", model: "gpt-5-codex", day: date,
                             totalTokens: 500_000, costUsd: 1.1))
            out.append(.init(provider: "codex", model: "gpt-5-mini", day: date,
                             totalTokens: 100_000, costUsd: 0.1))
        }
        return out
    }

    private func pattern(usage: ModelUsageInput) -> ModelPatternModel {
        PlanFitModelBuilder.build(
            rows: rows(), unit: .weekly, nowMs: WindowFixtures.nowMs, modelUsage: usage
        ).modelPattern
    }

    /// **T057, the core asymmetry.** Claude splits part of its weekly limit by
    /// model, so its per-model utilisation is a real observation. Every Codex
    /// window carries `limit_id="codex"` — there is no per-model utilisation to
    /// report — so its breakdown comes from token events, and the screen says
    /// so rather than presenting the two sides as symmetric.
    @Test("Codex has no per-model windows and the screen says so")
    func codexHasNoModelScopedWindows() {
        let model = pattern(usage: .reported(samples()))
        let claude = model.blocks.first { $0.id == "claude_code" }
        let codex = model.blocks.first { $0.id == "codex" }

        #expect(claude?.limitRows.isEmpty == false,
                "Claude's model-scoped weekly limits produced no per-model utilisation")
        #expect(claude?.limitRows.allSatisfy { $0.source == .windowLimits } == true)

        #expect(codex?.limitRows.isEmpty == true,
                "Codex was given per-model limit rows it cannot have")
        #expect(codex?.asymmetryNote?.isEmpty == false,
                "Codex's missing per-model limit reads as absent data, not as a fact about the provider")
        #expect(codex?.usageRows.isEmpty == false, "Codex has no breakdown at all")
        #expect(codex?.usageRows.allSatisfy { $0.source == .tokenEvents } == true)
    }

    /// FR-028. Every row says where it came from, and the two sources answer
    /// different questions — one is about a limit, the other is not.
    @Test("every row carries its source")
    func everyRowCarriesItsSource() {
        let model = pattern(usage: .reported(samples()))
        #expect(!model.blocks.isEmpty)
        for block in model.blocks {
            #expect(!block.sourceNote.isEmpty, "\(block.id) does not say where its rows came from")
            for row in block.limitRows + block.usageRows {
                #expect(!row.source.label.isEmpty)
                #expect(!row.source.explanation.isEmpty)
            }
            // A limit's utilisation is not a share of anything, so it never
            // gets a share bar or a share percentage.
            #expect(block.limitRows.allSatisfy { $0.sharePct == nil })
            #expect(block.usageRows.allSatisfy { $0.sharePct != nil })
        }
    }

    /// FR-026. Shares are per provider and add to 100 on each side — never
    /// across providers, whose token counts are different accounts of
    /// different work.
    @Test("shares are per provider and add up")
    func sharesArePerProvider() {
        let model = pattern(usage: .reported(samples()))
        for block in model.blocks where !block.usageRows.isEmpty {
            let total = block.usageRows.compactMap(\.sharePct).reduce(0, +)
            #expect(abs(total - 100) < 0.5, "\(block.id) shares add to \(total)")
        }
    }

    /// A failed token-events query is not "no models used". The first is a
    /// fact about the daemon, the second a fact about the account.
    @Test("unreadable token events are distinguished from having none")
    func unreadableIsNotEmpty() {
        let unread = pattern(usage: .notFetched)
        #expect(unread.unavailableNote?.isEmpty == false)
        #expect(unread.blocks.allSatisfy { $0.usageRows.isEmpty })
        // Claude's per-model limits still come through — they are read off the
        // windows, and one thin source must not blank the other.
        #expect(unread.blocks.first { $0.id == "claude_code" }?.limitRows.isEmpty == false,
                "an unreadable token query blanked the window-sourced rows too")

        let none = pattern(usage: .reported([]))
        #expect(none.unavailableNote == nil, "an empty answer is being reported as a failure")
    }

    /// The section renders in both themes at 800pt.
    @Test("the model section renders", arguments: PlanFitSnapshotTheme.allCases)
    func modelSectionRenders(theme: PlanFitSnapshotTheme) throws {
        let model = PlanFitModelBuilder.build(
            rows: rows(), unit: .weekly, nowMs: WindowFixtures.nowMs,
            modelUsage: .reported(samples())
        )
        let raster = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitContent(model: model, unit: .constant(.weekly)),
            theme: theme,
            size: CGSize(width: PlanFitSnapshotRenderer.width, height: 2800)
        ))
        #expect(raster.pageInkCoverage > 0.03)
        #expect(raster.pagePeakContrast >= 4.5)
        #expect(raster.edgeInk(margin: 8) == 0, "the model section overflows 800pt")
    }
}

// MARK: - Money never outranks limits (T058, T059)

@Suite("Plan-fit money placement")
@MainActor
struct PlanFitMoneyTests {

    /// A page with both providers, real spend, and enough windows for limit
    /// cards to exist — the layout the placement claim has to hold in.
    private func model() -> PlanFitModel {
        let now = Date(timeIntervalSince1970: Double(WindowFixtures.nowMs) / 1000)
        var samples: [ModelUsageSample] = []
        for day in 0..<20 {
            let date = now.addingTimeInterval(-Double(day) * 86_400)
            samples.append(.init(provider: "claude_code", model: "claude-opus-4-5", day: date,
                                 totalTokens: 800_000, costUsd: 6.5))
            samples.append(.init(provider: "codex", model: "gpt-5-codex", day: date,
                                 totalTokens: 400_000, costUsd: 1.25))
        }
        return PlanFitModelBuilder.build(
            rows: WindowFixtures.twoProviders(), unit: .weekly,
            nowMs: WindowFixtures.nowMs, modelUsage: .reported(samples)
        )
    }

    private func raster(_ model: PlanFitModel) -> PanelRaster? {
        PlanFitSnapshotRenderer.raster(
            PlanFitContent(model: model, unit: .constant(.weekly)),
            theme: .light,
            size: CGSize(width: PlanFitSnapshotRenderer.width, height: 3600)
        )
    }

    /// FR-045 / SC-005. Every figure carries "at current prices", because
    /// there is no price history — a cost is always computed against today's
    /// table, and a bare figure is a claim about the past that was never
    /// measured. `MoneyNote`'s initialiser makes it unrepresentable otherwise;
    /// this checks the type is the one being rendered from.
    @Test("every monetary figure carries its qualifier")
    func everyFigureIsQualified() {
        let money = model().money
        #expect(!money.notes.isEmpty)
        for note in money.notes {
            #expect(note.amount.contains("$"))
            #expect(note.qualifier == L.tr("현재 가격 기준", "at current prices"),
                    "\(note.label) prints \(note.amount) with no qualifier")
        }
        #expect(!money.placementNote.isEmpty)
    }

    /// A model whose price is unknown contributes nothing and is counted into
    /// the coverage line. Adding it as zero would understate the one figure on
    /// the page that is about money.
    @Test("a model with no known price is declared, not counted as zero")
    func unpricedModelsAreDeclared() {
        let now = Date(timeIntervalSince1970: Double(WindowFixtures.nowMs) / 1000)
        let money = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly, nowMs: WindowFixtures.nowMs,
            modelUsage: .reported([
                .init(provider: "claude_code", model: "known", day: now,
                      totalTokens: 100, costUsd: 3),
                .init(provider: "claude_code", model: "unpriced", day: now,
                      totalTokens: 100, costUsd: nil),
            ])
        ).money
        let note = money.notes.first
        #expect(note?.amount == "$3.00", "an unknown price was folded in as a number")
        #expect(note?.coverage?.isEmpty == false, "the excluded model is not declared")
    }

    /// No spend, no figure. An empty account does not get a "$0.00" that would
    /// read as a measurement.
    @Test("an account with no token events gets no monetary figure")
    func noEventsNoMoney() {
        let money = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountA(), unit: .weekly,
            nowMs: WindowFixtures.nowMs, modelUsage: .reported([])
        ).money
        #expect(money.isPresentable == false)
    }

    /// FR-046, as type sizes. Money may not reach the size of a supporting
    /// metric, let alone the page's conclusion.
    @Test("money is drawn smaller than any number it must not outrank")
    func moneyTypeIsSubordinate() {
        #expect(MoneyFootnote.amountSize < PlanFitType.metric,
                "money at \(MoneyFootnote.amountSize)pt against a metric at \(PlanFitType.metric)pt")
        #expect(MoneyFootnote.amountSize < PlanFitType.lede)
        #expect(MoneyFootnote.labelSize <= PlanFitType.caption)
        #expect(MoneyFootnote.qualifierSize <= MoneyFootnote.amountSize)
    }

    /// **T059 / SC-017, in pixels.** The claim is about position and weight, so
    /// it is measured rather than reviewed.
    ///
    /// Rendering the page with a block and without it leaves everything ABOVE
    /// that block pixel-identical, so the first differing row is the block's
    /// top edge. Money's top must come after the limit information starts, and
    /// money must put less ink on the page than the limit information does.
    @Test("money is below the limit information and lighter than it")
    func moneySitsBelowLimits() throws {
        let full = model()
        let withoutMoney = PlanFitModel(
            unit: full.unit, lede: full.lede, otherVerdicts: full.otherVerdicts,
            trend: full.trend, limitGroups: full.limitGroups, activeUse: full.activeUse,
            comparison: full.comparison, modelPattern: full.modelPattern,
            money: .empty, subscriptionComparison: full.subscriptionComparison,
            readiness: full.readiness,
            quietLimitsNote: full.quietLimitsNote, sourceNote: full.sourceNote
        )
        let withoutLimits = PlanFitModel(
            unit: full.unit, lede: full.lede, otherVerdicts: full.otherVerdicts,
            trend: full.trend, limitGroups: [], activeUse: [],
            comparison: full.comparison, modelPattern: full.modelPattern,
            money: full.money, subscriptionComparison: full.subscriptionComparison,
            readiness: full.readiness,
            quietLimitsNote: full.quietLimitsNote, sourceNote: full.sourceNote
        )

        let fullRaster = try #require(raster(full))
        let moneyRemoved = try #require(raster(withoutMoney))
        let limitsRemoved = try #require(raster(withoutLimits))

        let moneyTop = try #require(PanelRaster.firstDifferingRow(fullRaster, moneyRemoved),
                                    "removing money changed nothing — it is not on the page")
        let limitsTop = try #require(PanelRaster.firstDifferingRow(fullRaster, limitsRemoved),
                                     "removing the limit cards changed nothing")
        #expect(moneyTop > limitsTop,
                "money starts at row \(moneyTop), the limit information at \(limitsTop) — money is above it")

        // And it is the smaller of the two, so "below" is not being bought with
        // a bigger block further down the page.
        let moneyInk = fullRaster.pageInkCoverage - moneyRemoved.pageInkCoverage
        let limitInk = fullRaster.pageInkCoverage - limitsRemoved.pageInkCoverage
        #expect(moneyInk > 0, "money draws nothing")
        #expect(moneyInk < limitInk,
                "money puts \(moneyInk) of ink on the page against the limits' \(limitInk)")
    }

    /// The same in dark mode — a placement claim that only holds in one
    /// appearance is not a placement claim.
    @Test("the page with money on it renders in both themes",
          arguments: PlanFitSnapshotTheme.allCases)
    func moneyPageRenders(theme: PlanFitSnapshotTheme) throws {
        let raster = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitContent(model: model(), unit: .constant(.weekly)),
            theme: theme,
            size: CGSize(width: PlanFitSnapshotRenderer.width, height: 3600)
        ))
        #expect(raster.pagePeakContrast >= 4.5)
        #expect(raster.edgeInk(margin: 8) == 0)
    }
}

// MARK: - Empty and insufficient (T060…T065)

@Suite("Plan-fit day one")
@MainActor
struct PlanFitReadinessTests {

    private func model(
        _ rows: [(provider: String, row: WindowRow)],
        unit: PeriodUnit = .weekly,
        availability: AccountShapeAvailability = .absent(.accountShapeNotSent),
        usage: ModelUsageInput = .notFetched
    ) -> PlanFitModel {
        PlanFitModelBuilder.build(
            rows: rows, unit: unit, nowMs: WindowFixtures.nowMs,
            modelUsage: usage, windowsAvailability: availability
        )
    }

    /// T060. Zero windows is guidance, not an error and not a chart of zeroes —
    /// and the conditions are enumerated so a reader can find which one is
    /// missing instead of parsing a paragraph.
    @Test("the zero-window screen names what has to be true")
    func zeroWindowsIsGuidance() {
        let readiness = model([]).readiness
        #expect(readiness.collectionNotStarted)
        #expect(readiness.headline?.isEmpty == false)
        #expect(readiness.requirements.count >= 3,
                "day one gets \(readiness.requirements.count) conditions — not enough to act on")
        #expect(readiness.gap == nil, "an empty account is being reported as a daemon fault")
        // The two providers fill in differently, and the screen says so.
        #expect(readiness.requirements.contains { $0.contains("Codex") })
    }

    /// T061. A few days of history shows every observed fact and withholds the
    /// interpretation — the verdict, and reading a direction into the bars.
    @Test("a few days shows the facts and withholds the reading")
    func fewDaysShowsFactsOnly() {
        let rows = PlanFitSnapshotMatrix.rows(
            for: PlanFitSnapshotCase(sufficiency: .fewDays, segments: .one, theme: .light)
        )
        let built = model(rows)
        // The facts are on the page.
        #expect(built.hasSegments)
        #expect(!built.trend.isEmpty, "the observed bars were dropped along with the reading")
        // The readings are not.
        let verdict = built.readiness.metrics.first { $0.id == "metric|verdict" }
        #expect(verdict?.status == .withheld)
        #expect(verdict?.reason.isEmpty == false)
        let trend = built.readiness.metrics.first { $0.id == "metric|trend" }
        #expect(trend?.status != .ready,
                "three days of history is being read as a trend")
        #expect(trend?.reason.isEmpty == false)
    }

    /// T062. A period still running is named, and compared on its daily average
    /// rather than on a total that is only part of a month.
    @Test("an unfinished period is named rather than compared away")
    func unfinishedPeriodIsNamed() {
        let rows = PlanFitSnapshotMatrix.rows(
            for: PlanFitSnapshotCase(sufficiency: .sufficient, segments: .one, theme: .light)
        )
        let built = model(rows, unit: .monthly)
        guard let last = built.trend.bars.last, !last.isComplete else { return }
        #expect(built.readiness.incompletePeriodNote?.isEmpty == false,
                "the period still running is not named anywhere")
    }

    /// **T063, the point of the whole block.** Sufficiency is judged per
    /// metric: a thin verdict must not take the limit statistics down with it.
    @Test("one thin metric does not blank the others")
    func sufficiencyIsPerMetric() {
        let rows = PlanFitSnapshotMatrix.rows(
            for: PlanFitSnapshotCase(sufficiency: .fewDays, segments: .four, theme: .light)
        )
        let built = model(rows)
        let byId = Dictionary(uniqueKeysWithValues: built.readiness.metrics.map { ($0.id, $0) })
        #expect(byId["metric|verdict"]?.status == .withheld)
        #expect(byId["metric|limits"]?.status == .ready,
                "the limit statistics went withheld because the verdict did")
        // And the sections themselves are still populated.
        #expect(!built.limitGroups.isEmpty)
        #expect(built.readiness.metrics.count >= 6, "not every metric is being judged")
        #expect(Set(built.readiness.metrics.map(\.id)).count == built.readiness.metrics.count)
        // Only the unready ones are drawn — the rest are on the page as
        // themselves, and repeating them would make this a checklist.
        #expect(built.readiness.unreadyMetrics.allSatisfy { !$0.isReady })
    }

    /// Every withheld metric says when it stops being withheld, where that is
    /// knowable at all (contract V1).
    @Test("a withheld metric says what is missing")
    func withheldMetricsExplainThemselves() {
        for sufficiency in PlanFitDataSufficiency.allCases {
            let rows = PlanFitSnapshotMatrix.rows(
                for: PlanFitSnapshotCase(sufficiency: sufficiency, segments: .four, theme: .light)
            )
            for metric in model(rows).readiness.unreadyMetrics {
                #expect(!metric.reason.isEmpty,
                        "\(sufficiency.rawValue): \(metric.metric) is withheld with no reason")
            }
        }
    }

    /// **T064.** A daemon that cannot serve windows is a capability gap, not an
    /// error — and `AccountShapeAbsence`'s four causes stay four causes.
    @Test("the four reasons a daemon serves no windows stay four reasons")
    func capabilityGapsAreNotCollapsed() {
        let absences: [AccountShapeAbsence] = [
            .windowsMetricUnsupported, .accountShapeNotSent,
            .windowStateUnavailable, .daemonUnreachable,
        ]
        var seen: Set<String> = []
        for absence in absences {
            let gap = model([], availability: .absent(absence)).readiness.gap
            switch absence {
            case .accountShapeNotSent:
                // The account object is a Claude profile field and Codex has no
                // equivalent; its absence says nothing about window support.
                #expect(gap == nil, "a missing account object is being reported as a broken feature")
            default:
                guard let gap else {
                    Issue.record("\(absence) produced no capability gap")
                    continue
                }
                #expect(!gap.headline.isEmpty, "\(absence) has no headline")
                #expect(!gap.explanation.isEmpty)
                #expect(gap.remedy?.isEmpty == false, "\(absence) says nothing the reader can do")
                seen.insert(gap.headline)
            }
        }
        #expect(seen.count == 3, "the three window-serving failures share wording: \(seen)")

        // Only one of them is a fault. The rest are states a working system
        // reaches, and drawing them as errors is what contract W4 forbids.
        #expect(model([], availability: .absent(.daemonUnreachable)).readiness.gap?.isFailure == true)
        #expect(model([], availability: .absent(.windowsMetricUnsupported)).readiness.gap?.isFailure == false)
        #expect(model([], availability: .absent(.windowsMetricUnsupported)).readiness.gap?.isCapabilityGap == true)
        #expect(model([], availability: .absent(.windowStateUnavailable)).readiness.gap?.isFailure == false)
    }

    /// A page with everything says nothing here.
    @Test("a page that can read every metric shows no readiness block")
    func fullPageHasNoReadinessBlock() {
        let built = PlanFitModelBuilder.build(
            rows: WindowFixtures.accountB(), unit: .weekly, nowMs: WindowFixtures.nowMs
        )
        #expect(built.readiness.collectionNotStarted == false)
        #expect(built.readiness.gap == nil)
    }

    // MARK: T065 — the screens, in pixels

    /// The screens a reader on day one, day three and day eighteen actually
    /// meets, plus the capability gap and the dead daemon. These are the ones
    /// most users will spend the most time on, so they are rendered rather than
    /// asserted about.
    @Test("every insufficient screen renders as a full page",
          arguments: PlanFitSnapshotTheme.allCases)
    func insufficientScreensRender(theme: PlanFitSnapshotTheme) throws {
        let screens: [(String, PlanFitModel)] = [
            ("day one", model([])),
            ("old daemon", model([], availability: .absent(.windowsMetricUnsupported))),
            ("tracking off", model([], availability: .absent(.windowStateUnavailable))),
            ("daemon down", model([], availability: .absent(.daemonUnreachable))),
            ("a few days", model(PlanFitSnapshotMatrix.rows(
                for: PlanFitSnapshotCase(sufficiency: .fewDays, segments: .four, theme: theme)))),
            ("under the gate", model(PlanFitSnapshotMatrix.rows(
                for: PlanFitSnapshotCase(sufficiency: .underLookback, segments: .eight, theme: theme)))),
        ]
        for (name, built) in screens {
            let raster = try #require(PlanFitSnapshotRenderer.raster(
                PlanFitContent(model: built, unit: .constant(.weekly)),
                theme: theme,
                size: CGSize(width: PlanFitSnapshotRenderer.width, height: 1600)
            ), "\(name) did not render")
            #expect(raster.pageInkCoverage > 0.03,
                    "\(name) (\(theme.rawValue)) is nearly empty: \(raster.pageInkCoverage)")
            #expect(raster.pagePeakContrast >= 4.5, "\(name) (\(theme.rawValue)) has no readable text")
            #expect(raster.edgeInk(margin: 8) == 0, "\(name) (\(theme.rawValue)) overflows 800pt")
        }
    }

    /// The day-one screen is not a thinner version of the populated one — it
    /// carries a comparable amount of text, because what it has to say is a
    /// comparable amount of information.
    @Test("day one is not a stub beside a populated page")
    func dayOneIsNotAStub() throws {
        let empty = try #require(PlanFitSnapshotRenderer.raster(
            PlanFitContent(model: model([]), unit: .constant(.weekly)),
            theme: .light,
            size: CGSize(width: PlanFitSnapshotRenderer.width, height: 900)
        ))
        #expect(empty.pageInkCoverage > 0.05,
                "the screen every existing user opens first draws \(empty.pageInkCoverage)")
        #expect(empty.pagePixelsAbove(contrast: 4.5) > 400,
                "day one is drawn but barely readable")
    }
}
