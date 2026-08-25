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
    @State private var isLoading = false
    @State private var loadFailed = false
    /// true = rows came from the sync server (multi-device merged statistics).
    @State private var usingServerData = false

    private let serverClient = ServerQueryClient()

    var body: some View {
        PlanFitContent(
            model: PlanFitModelBuilder.build(
                rows: rows,
                unit: periodUnit,
                nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                usingServerData: usingServerData,
                loadFailed: loadFailed,
                isLoading: isLoading
            ),
            unit: $periodUnit
        )
        .task { await load() }
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
        let (localRows, localFailed) = await localAsync
        let (serverRows, serverFailed) = await serverAsync

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
                ProvenanceLegend()
            }
            .padding(DS.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(L.tr("이 페이지의 유일한 설정입니다", "The page's only setting"))
                .font(.system(size: PlanFitType.tiny))
                .foregroundStyle(PlanFitInk.faint)
        }
    }
}
