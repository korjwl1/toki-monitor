import SwiftUI

// MARK: - The plan-fit page (T043, T044, T049, T050, T052)
//
// A curated page, not a locked dashboard preset (constitution VI). The two
// layers share the domain aggregation and nothing else, and the difference
// shows up here as a structural rule rather than as a convention:
//
//   **The period unit is the only control, and it is the only control the code
//   can express.** `PlanFitContent` holds exactly one `Binding` — the unit —
//   and every section below it takes a value and returns a view. Sections have
//   no bindings and no closures, so there is nothing for an editor entry point
//   to be attached to; a Button anywhere in this view tree changes the STATIC
//   TYPE of `PlanFitContent.body`, which is what `PlanFitControlSurfaceTests`
//   reads. The refresh button the old page carried is gone for the same
//   reason: FR-001 says one control, and "one control plus a refresh" is two.
//
// The other half of the rebuild is hierarchy (research §5). The verdict used
// to render at 10pt as a top-right caption while supporting statistics
// rendered at 12pt. It now leads the page at 24pt — a 1.6x step over the
// largest supporting number — and the sections beneath it are evidence for it,
// in the order a reader needs them: what the conclusion is, how usage is
// trending, how each limit is running, and what was happening while the user
// was actually working.

struct PlanFitPage: View {
    let reportClient: TokiReportClient

    /// FR-006: the choice survives relaunch. `@AppStorage` rather than a row
    /// in `AppSettings` because this is the page's own state, not a preference
    /// the settings window should offer (FR-063 keeps *settings* out of the
    /// page; it does not make the page's one control a setting).
    @AppStorage("planFit.periodUnit") private var periodUnit: PeriodUnit = .weekly

    @State private var rows: [(provider: String, row: WindowRow)] = []
    /// Token events per provider per model. The only source of a per-model
    /// breakdown for Codex, which has no model-scoped windows at all.
    @State private var modelUsage: ModelUsageInput = .notFetched
    /// Whether the daemon can serve windows at all. A daemon that cannot is a
    /// capability gap, not an error, and the four causes want four screens
    /// (contract W4).
    @State private var windowsAvailability: AccountShapeAvailability = .absent(.accountShapeNotSent)
    @State private var isLoading = false
    @State private var loadFailed = false
    /// true = rows came from the sync server (multi-device merged statistics).
    @State private var usingServerData = false

    /// The instant the page reasons about, held in state rather than read in
    /// `body`.
    ///
    /// `Date()` inside `body` made the model a different value on every render
    /// — SwiftUI could not treat two renders of unchanged state as equal, and
    /// the whole 28-day derivation (percentiles, verdicts, every string on the
    /// page) ran again each time. Stamped once per load and once per period
    /// change, which are the only moments the answer can actually differ.
    @State private var nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    private let serverClient = ServerQueryClient()

    var body: some View {
        PlanFitContent(
            model: PlanFitModelBuilder.build(
                rows: rows,
                unit: periodUnit,
                nowMs: nowMs,
                modelUsage: modelUsage,
                windowsAvailability: windowsAvailability,
                usingServerData: usingServerData,
                loadFailed: loadFailed,
                isLoading: isLoading
            ),
            unit: $periodUnit
        )
        .task { await load() }
        // Switching weekly/monthly re-derives against a fresh instant. Without
        // this the page would keep reasoning about the moment of the last load,
        // which is the cost of taking `now` out of `body`.
        .onChange(of: periodUnit) { _, _ in
            nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    // MARK: - Data

    private func load() async {
        // .task re-fires on every appearance and the CLI subprocess is not
        // cancellation-aware — a second load racing the first could interleave
        // partial state. One at a time.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let now = Int(Date().timeIntervalSince1970)
        nowMs = Int64(now) * 1000
        let start = now - Int(WindowStats.lookbackDays * 86_400)
        // Both sources bound on the window ANCHOR, which is the reset instant —
        // in the FUTURE for every open window. Ending at `now` therefore filtered
        // out exactly the open rows that current-tier detection needs (after a
        // plan change the newest finalized weekly row still names the old tier,
        // for up to 7 days). Statistics are unaffected: they require `finalized`.
        let end = now + 7 * 86_400 + 3_600
        // Both sources fetched in PARALLEL and arbitrated PER PROVIDER: the
        // server (multi-device merge) wins for providers it actually has, but
        // a server that only knows Claude must not discard richer local
        // Codex history — and a broken local CLI must not gate the server.
        async let localAsync = fetchLocal(start: start, end: end)
        async let serverAsync = fetchServer(start: start, end: end)
        async let usageAsync = fetchModelUsage(start: start, end: now)
        // Cheap: the coordinator serves back-to-back requests from a 5s cache,
        // and this is the only thing that can tell an old daemon apart from an
        // account that simply has no windows yet.
        async let capabilityAsync = TokiWindowsClient.fetch(maxAgeMs: nil)
        let (localRows, localFailed) = await localAsync
        let (serverRows, serverFailed) = await serverAsync
        modelUsage = await usageAsync
        windowsAvailability = AccountShapeAvailability.from(await capabilityAsync)

        var serverProviders = Set<String>()
        for entry in serverRows { serverProviders.insert(entry.provider) }
        var fetched = serverRows
        for entry in localRows where !serverProviders.contains(entry.provider) {
            fetched.append(entry)
        }
        // Only claim "all devices merged" when EVERY rendered provider came
        // from the server; per-provider arbitration can mix sources.
        var localProviders = Set<String>()
        for entry in localRows { localProviders.insert(entry.provider) }
        usingServerData = !serverRows.isEmpty && localProviders.isSubset(of: serverProviders)

        rows = fetched
        // Distinguish "both sources answered: no data yet" (guidance screen)
        // from "every source FAILED" (real problem): masking a missing CLI or
        // a server 500 as 'no data' hides it, and the two screens say
        // different things about what the reader should do next.
        loadFailed = fetched.isEmpty && localFailed && serverFailed
    }

    private func fetchLocal(start: Int, end: Int) async -> ([(provider: String, row: WindowRow)], failed: Bool) {
        do { return (try await reportClient.queryWindows(startEpoch: start, endEpoch: end), false) }
        catch { return ([], true) }
    }

    private func fetchServer(start: Int, end: Int) async -> ([(provider: String, row: WindowRow)], failed: Bool) {
        do { return (try await serverClient.queryWindows(startEpoch: start, endEpoch: end), false) }
        catch { return ([], true) }
    }

    /// Per-model token usage, in daily buckets, keeping the provider key.
    ///
    /// Daily rather than at the page's period unit: the unit is a control the
    /// reader flips, and re-querying the daemon on every flip would make a
    /// display choice cost a subprocess. Days re-bucket into weeks and months
    /// locally, on the same boundaries the trend uses.
    private func fetchModelUsage(start: Int, end: Int) async -> ModelUsageInput {
        do {
            let byProvider = try await reportClient.queryModelUsageByProvider(
                query: "usage[1d] by (model)",
                since: "\(start)",
                until: "\(end)"
            )
            var samples: [ModelUsageSample] = []
            for (provider, points) in byProvider {
                for (day, summaries) in points {
                    for summary in summaries {
                        guard summary.totalTokens > 0 else { continue }
                        samples.append(ModelUsageSample(
                            provider: provider,
                            model: summary.model,
                            day: day,
                            totalTokens: Double(summary.totalTokens),
                            costUsd: summary.costUsd,
                            costFromCompiledTable: summary.costFromCompiledTable
                        ))
                    }
                }
            }
            return .reported(samples)
        } catch {
            // A failed query is NOT "no models used". The two say different
            // things about the account and get different screens.
            return .notFetched
        }
    }
}

// MARK: - The page, as a pure function of its model

/// Everything the page draws, given a value and the one control.
///
/// Split from `PlanFitPage` so the whole screen — header, toggle and all — can
/// be rendered from fixtures with no daemon, no network and no clock. Nobody
/// reviewing this work can see the screen, so the render has to be something a
/// machine can look at.
struct PlanFitContent: View {
    let model: PlanFitModel
    /// The page's one and only control (FR-001).
    @Binding var unit: PeriodUnit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.lg) {
                header
                VerdictSection(lede: model.lede, others: model.otherVerdicts)
                // Directly under the conclusion: what the page cannot yet say
                // is part of the conclusion, not a footnote to it.
                if model.readiness.isPresentable {
                    EmptyStateSection(model: model.readiness)
                }
                PeriodTrendSection(model: model.trend)
                if model.hasSegments {
                    LimitStatusSection(groups: model.limitGroups)
                    ActiveUseSection(
                        limits: model.activeUse,
                        quietLimitsNote: model.quietLimitsNote
                    )
                }
                if model.comparison.isPresentable {
                    ProviderComparisonSection(model: model.comparison)
                }
                if model.modelPattern.isPresentable {
                    ModelPatternSection(model: model.modelPattern)
                }
                // Always drawn, in every state (T067). This block's usual
                // content is a refusal, and a refusal that hides itself is
                // indistinguishable from a feature that forgot to run.
                SubscriptionComparisonSection(model: model.subscriptionComparison)
                // Last, and smallest. FR-046: on a flat-rate subscription the
                // limits and the headroom are what the page is for, and money
                // may not out-rank them visually.
                if model.money.isPresentable {
                    MoneyFootnote(model: model.money)
                }
                ProvenanceLegend()
            }
            .padding(DS.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // T071. Two things, both of them about a reader who never touches the
        // trackpad. `focusable` puts the scroll view in the key loop, which is
        // what makes arrow keys and Page Up/Down move the page at all; without
        // it the only focus stop on the screen is the picker, and a reader who
        // tabs to it can change the unit but cannot read the evidence.
        //
        // `onKeyPress` then gives the one control a reachable shortcut from
        // anywhere on the page rather than only while the picker holds focus —
        // otherwise "keyboard support" would mean tabbing back to the top of a
        // long page to flip a toggle whose effect is at the bottom of it.
        // Returning `.ignored` for everything else is what leaves the arrow
        // keys doing their scrolling job.
        .focusable()
        .onKeyPress { press in
            guard let next = PlanFitKeyboard.unit(movingFrom: unit, key: press.key) else {
                return .ignored
            }
            unit = next
            return .handled
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.lg) {
            VStack(alignment: .leading, spacing: DS.xs) {
                Text(L.tr("요금제 적합도", "Plan Fit"))
                    .font(.system(size: PlanFitType.sectionTitle, weight: .semibold))
                    .foregroundStyle(PlanFitInk.support)
                Text(L.tr(
                    "최근 \(Int(WindowStats.lookbackDays))일의 rate-limit 윈도우 기록. 다른 사용자와 비교하지 않으며, 이 데이터는 기기를 벗어나지 않습니다.",
                    "The trailing \(Int(WindowStats.lookbackDays)) days of rate-limit windows. Nothing here compares you with anyone else, and none of it leaves this machine."
                ))
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.faint)
                .fixedSize(horizontal: false, vertical: true)
                if let sourceNote = model.sourceNote {
                    Text(sourceNote)
                        .font(.system(size: PlanFitType.tiny))
                        .foregroundStyle(PlanFitInk.faint)
                }
            }
            Spacer(minLength: DS.sm)
            periodPicker
        }
    }

    /// The only control on the page. Segmented so both options are visible and
    /// reachable from the keyboard without opening anything (FR-060).
    private var periodPicker: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Picker(L.tr("기간 단위", "Period unit"), selection: $unit) {
                ForEach(PeriodUnit.allCases, id: \.self) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .accessibilityLabel(L.tr("기간 단위", "Period unit"))
            .accessibilityHint(PlanFitKeyboard.hint)
            Text(L.tr("이 페이지의 유일한 설정입니다", "The page's only setting"))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
            // The shortcut is written down beside the control it drives.
            // A keyboard affordance nobody is told about is one most people
            // never find.
            Text(PlanFitKeyboard.hint)
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
        }
    }
}
