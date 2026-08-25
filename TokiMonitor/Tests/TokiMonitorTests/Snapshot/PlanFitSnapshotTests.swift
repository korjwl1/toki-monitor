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
            ("PeriodTrendSection", PeriodTrendSection(model: model.trend)),
            ("LimitStatusSection", LimitStatusSection(groups: model.limitGroups)),
            ("ActiveUseSection", ActiveUseSection(limits: model.activeUse,
                                                  quietLimitsNote: model.quietLimitsNote)),
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
