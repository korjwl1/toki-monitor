import SwiftUI
import Charts

/// Plan-fit analytics: long-term rate-limit window statistics per provider.
///
/// Deliberately a fixed view rather than a PanelPlugin: the panel pipeline's
/// contract is TimeSeriesData, and window statistics (percentiles over window
/// instances, censoring flags, tier advice) are not a time series. Forcing
/// them through that contract would mean fake models; a dedicated view is the
/// honest shape. (Documented deviation from the original plan §3.5.)
struct PlanFitView: View {
    let reportClient: TokiReportClient

    @State private var segments: [WindowStatsSegment] = []
    @State private var rows: [(provider: String, row: WindowRow)] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var firstSeen: Date?
    /// true = rows came from the sync server (multi-device merged statistics).
    @State private var usingServerData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.lg) {
                header
                if isLoading && segments.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let loadError {
                    Text(loadError)
                        .font(.system(size: DS.fontBody))
                        .foregroundStyle(.secondary)
                } else if segments.isEmpty {
                    emptyState
                } else {
                    ForEach(segments, id: \.self) { segment in
                        segmentCard(segment)
                    }
                }
            }
            .padding(DS.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: DS.xs) {
                Text(L.tr("요금제 적합도", "Plan Fit"))
                    .font(.system(size: DS.fontTitle, weight: .semibold))
                Text(L.tr(
                    "최근 28일 rate-limit 윈도우 통계 — 한도 소진 빈도와 peak 분포로 요금제 여유를 진단합니다",
                    "Trailing 28-day rate-limit window statistics — limit exhaustion and peak distribution"
                ))
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(.secondary)
                if usingServerData {
                    Text(L.tr("동기화 서버 데이터 (전체 디바이스 병합)", "Sync-server data (all devices merged)"))
                        .font(.system(size: DS.fontTiny))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(L.tr("아직 윈도우 데이터가 없습니다", "No window data yet"))
                .font(.system(size: DS.fontBody, weight: .medium))
            Text(L.tr(
                "toki daemon(v2.3+)이 사용량 윈도우를 수집하면 여기에 통계가 쌓입니다. Codex는 과거 세션에서 즉시 복원되고, Claude는 수집 시작 후 4주에 걸쳐 채워집니다.",
                "Statistics accumulate once toki daemon (v2.3+) records usage windows. Codex history backfills immediately; Claude ramps over ~4 weeks from collection start."
            ))
            .font(.system(size: DS.fontCaption))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.lg)
        .background(RoundedRectangle(cornerRadius: DS.widgetRadius).fill(.quaternary.opacity(0.3)))
    }

    // MARK: - Segment card

    private func segmentCard(_ s: WindowStatsSegment) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(spacing: DS.sm) {
                Text(providerTitle(s.provider))
                    .font(.system(size: DS.fontBody, weight: .semibold))
                Text(kindLabel(s.kind))
                    .font(.system(size: DS.fontCaption))
                    .padding(.horizontal, DS.sm).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                if !s.plan.isEmpty {
                    Text(s.plan)
                        .font(.system(size: DS.fontCaption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                adviceBadge(s.advice)
            }

            peakHistoryChart(for: s)

            HStack(spacing: DS.lg) {
                stat(
                    L.tr("한도 소진", "Maxed out"),
                    "\(s.maxedCount) / \(s.activeWindowCount)",
                    detail: s.medianTimeTo100Sec.map {
                        L.tr("중앙값 \(formatDuration($0))만에 소진", "median \(formatDuration($0)) to hit")
                    }
                )
                stat(
                    L.tr("Peak 분포", "Peak distribution"),
                    percentileText(s),
                    detail: s.p95IsCensored
                        ? L.tr("일부 윈도우가 100%에서 잘림(실수요는 더 높음)", "some windows censored at 100% (true demand higher)")
                        : nil
                )
                stat(
                    L.tr("사용 중 평균", "Active mean"),
                    s.meanPeakActive.map { "\(Int($0))%" } ?? "—",
                    detail: s.approxOverallMean.map {
                        L.tr("전체 평균 ~\(Int($0))% (캘린더 근사)", "overall ~\(Int($0))% (calendar approx.)")
                    }
                )
                stat(
                    L.tr("가동률", "Duty cycle"),
                    "\(Int(s.dutyCycle * 100))%",
                    detail: s.impliedDemandP90.map {
                        L.tr("잠재 수요 p90 ~\(Int($0))%", "implied demand p90 ~\(Int($0))%")
                    }
                )
            }
        }
        .padding(DS.lg)
        .background(RoundedRectangle(cornerRadius: DS.widgetRadius).fill(.quaternary.opacity(0.3)))
    }

    private func peakHistoryChart(for s: WindowStatsSegment) -> some View {
        let history = rows
            .filter {
                $0.provider == s.provider && $0.row.kind == s.kind
                    && $0.row.plan == s.plan && $0.row.account == s.account
                    && $0.row.finalized
            }
            .map(\.row)
            .sorted { $0.windowEndMs < $1.windowEndMs }
            .suffix(60)

        return Chart(Array(history), id: \.windowEndMs) { row in
            BarMark(
                x: .value("Reset", Date(timeIntervalSince1970: Double(row.windowEndMs) / 1000)),
                y: .value("Peak %", row.peakPct)
            )
            .foregroundStyle(row.maxedOut ? Color.red : (row.peakPct > 75 ? Color.orange : Color.accentColor))
        }
        .chartYScale(domain: 0...100)
        .frame(height: 120)
    }

    private func stat(_ title: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: DS.fontBody, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: DS.fontTiny))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adviceBadge(_ advice: TierAdvice) -> some View {
        let (text, color): (String, Color) = {
            switch advice {
            case .collecting(let days):
                return (L.tr("수집 중 (\(days)일째)", "Collecting (day \(days))"), .secondary)
            case .upgrade(let reason):
                return (L.tr("업그레이드 고려 — \(reason)", "Consider upgrade — \(reason)"), .orange)
            case .downgrade(let reason):
                return (L.tr("다운그레이드 여지 — \(reason)", "Downgrade room — \(reason)"), .blue)
            case .keep(let reason):
                return (L.tr("적정 — \(reason)", "Right-sized — \(reason)"), .green)
            case .evidenceOnly:
                return (L.tr("근거만 표시 (플랜 미확인)", "Evidence only (plan unknown)"), .secondary)
            }
        }()
        return Text(text)
            .font(.system(size: DS.fontCaption))
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let now = Int(Date().timeIntervalSince1970)
        let start = now - Int(WindowStats.lookbackDays * 86_400)
        do {
            var fetched = try await reportClient.queryWindows(startEpoch: start, endEpoch: now)
            usingServerData = false
            // Multi-device accounts: the server's rows are the field-wise merge
            // of every synced device — prefer them when sync is configured and
            // the fetch succeeds; the local daemon remains the fallback.
            if let serverRows = try? await ServerQueryClient().queryWindows(startEpoch: start, endEpoch: now),
               !serverRows.isEmpty {
                fetched = serverRows
                usingServerData = true
            }
            rows = fetched
            segments = WindowStats.segments(rows: fetched)
            firstSeen = fetched.map(\.row.firstSeenMs).min()
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
            loadError = nil
        } catch {
            loadError = L.tr(
                "윈도우 데이터를 불러오지 못했습니다 — toki daemon(v2.3+)이 실행 중인지 확인하세요",
                "Could not load window data — check that toki daemon (v2.3+) is running"
            )
        }
    }

    private func providerTitle(_ name: String) -> String {
        switch name {
        case "claude_code": return "Claude Code"
        case "codex": return "Codex"
        default: return name
        }
    }

    private func kindLabel(_ kind: String) -> String {
        kind == "session" ? L.tr("5시간", "5-hour") : L.tr("주간", "Weekly")
    }

    private func percentileText(_ s: WindowStatsSegment) -> String {
        guard let p50 = s.p50Peak, let p95 = s.p95Peak else { return "—" }
        let p95Str = s.p95IsCensored ? "≥\(Int(p95))%" : "\(Int(p95))%"
        return "p50 \(Int(p50))% · p95 \(p95Str)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 { return L.tr("\(hours / 24)일 \(hours % 24)시간", "\(hours / 24)d \(hours % 24)h") }
        if hours > 0 { return L.tr("\(hours)시간 \(minutes)분", "\(hours)h \(minutes)m") }
        return L.tr("\(minutes)분", "\(minutes)m")
    }
}
