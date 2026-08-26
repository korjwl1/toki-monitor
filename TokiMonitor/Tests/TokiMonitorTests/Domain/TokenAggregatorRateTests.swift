import Foundation
import Testing
@testable import TokiMonitor

/// `TokenAggregator` turns the trace stream into the number in the menu bar.
/// Everything that does the turning — `emaTick`, `pruneTraceEvents`,
/// `recalculateSessionCounts`, `updateSpendAlert` — is `private`, and the only
/// public trigger for any of it is `startSampling()`, which installs a 1 Hz
/// `Timer`. So these tests drive the real timer and wait for real ticks, and
/// assert on the published properties.
///
/// One consequence has to be stated plainly: `startSampling()` also calls
/// `fetchHistoricalBaseline()`, which runs `toki query -z UTC --output-format
/// json 'usage[24h] by (model)'` — a read against the live daemon, the same
/// query the app itself issues on every launch. There is no seam to put a
/// fixture behind it (`TokiReportClient` is constructed inline and resolves
/// `TokiPath` itself). No test here writes anything, and the number that query
/// returns is never asserted on; the suite is kept small to keep the number of
/// those reads small.
@MainActor
@Suite("TokenAggregator — the live rate", .serialized)
struct TokenAggregatorRateTests {

    // MARK: - Harness

    private func event(model: String, source: String = "s1", tokens: UInt64, cost: Double? = nil) -> TokenEvent {
        let json = """
        {"model":"\(model)","source":"\(source)","input_tokens":\(tokens),"output_tokens":0,
         "cache_creation_input_tokens":0,"cache_read_input_tokens":0\(cost.map { ",\"cost_usd\":\($0)" } ?? "")}
        """
        let data = try! JSONDecoder().decode(TokiEventData.self, from: Data(json.utf8))
        return TokenEvent(from: data)
    }

    /// Polls until `condition` holds. Sleeping returns to the run loop, which
    /// is what lets the aggregator's `Timer` fire at all.
    @discardableResult
    private func wait(upTo seconds: Double = 6, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func ticks(_ n: Int) async {
        try? await Task.sleep(for: .milliseconds(Int(1100 * n)))
    }

    // MARK: - Rate

    @Test("An event raises the rate, and with nothing following it the rate decays")
    func rateRisesThenDecays() async {
        let aggregator = TokenAggregator()
        aggregator.startSampling()
        defer { aggregator.stopSampling() }

        #expect(aggregator.tokensPerMinute == 0, "nothing has happened yet")

        aggregator.addEvent(event(model: "claude-opus-4-6", tokens: 100_000))
        let rose = await wait { aggregator.tokensPerMinute > 0 }
        #expect(rose, "a 100k-token event must move the rate within a few ticks")

        let peak = aggregator.tokensPerMinute
        await ticks(2)
        let after = aggregator.tokensPerMinute
        #expect(after < peak, "with no further events the EMA must fall, not hold")
        #expect(after >= 0)
    }

    @Test("A trickle too small to mean anything reports as zero, not as dust")
    func belowTheClampIsZero() async {
        let aggregator = TokenAggregator()
        aggregator.startSampling()
        defer { aggregator.stopSampling() }

        // 1 token/tick lands near 18 tok/min after the EMA blend, under the
        // 100 tok/min floor the class clamps to zero. Without the clamp the
        // menu bar would sit at a non-zero number forever.
        aggregator.addEvent(event(model: "claude-opus-4-6", tokens: 1))
        await ticks(2)
        #expect(aggregator.tokensPerMinute == 0)
    }

    @Test("Two providers keep separate rates and separate session counts")
    func providersStaySeparate() async {
        let aggregator = TokenAggregator()
        aggregator.startSampling()
        defer { aggregator.stopSampling() }

        let claude = ProviderRegistry.resolve(model: "claude-opus-4-6").id
        let codex = ProviderRegistry.resolve(model: "gpt-5.4").id
        try? #require(claude != codex)

        // Two sessions on one provider, one on the other.
        aggregator.addEvent(event(model: "claude-opus-4-6", source: "a", tokens: 100_000))
        aggregator.addEvent(event(model: "claude-opus-4-6", source: "a", tokens: 100_000))
        aggregator.addEvent(event(model: "claude-opus-4-6", source: "b", tokens: 100_000))
        aggregator.addEvent(event(model: "gpt-5.4", source: "c", tokens: 100_000))

        let settled = await wait { (aggregator.perProviderRates[claude] ?? 0) > 0 && (aggregator.perProviderRates[codex] ?? 0) > 0 }
        #expect(settled, "each provider must get its own rate")
        #expect((aggregator.perProviderRates[claude] ?? 0) > (aggregator.perProviderRates[codex] ?? 0),
                "three events must not rate the same as one")

        #expect(aggregator.perProviderSessionCount[claude] == 2, "two distinct sources, not three events")
        #expect(aggregator.perProviderSessionCount[codex] == 1)
        #expect(aggregator.tokensPerMinute > 0, "the global rate covers both providers")
    }

    @Test("With no settings attached there is no spend alert to raise")
    func noSettingsNoAlert() async {
        let aggregator = TokenAggregator()
        #expect(aggregator.settings == nil)
        aggregator.startSampling()
        defer { aggregator.stopSampling() }

        // A cost far above any plausible threshold. Without a settings object
        // there is nothing to compare it to, and inventing a default here
        // would alarm every user who never configured one.
        aggregator.addEvent(event(model: "claude-opus-4-6", tokens: 100_000, cost: 500))
        await ticks(2)

        #expect(aggregator.spendAlert == .normal)
        #expect(aggregator.perProviderSpendAlerts.isEmpty)
    }

    // MARK: - Sampling lifecycle

    @Test("stopSampling really stops: events after it move nothing")
    func stopSamplingHalts() async {
        let aggregator = TokenAggregator()
        aggregator.startSampling()
        aggregator.stopSampling()

        aggregator.addEvent(event(model: "claude-opus-4-6", tokens: 100_000))
        await ticks(2)
        #expect(aggregator.tokensPerMinute == 0, "a stopped aggregator must not keep ticking")
    }

    @Test("The report poll is off until something asks for it, and toggling is idempotent")
    func reportActiveGate() {
        // No sampling is running, so this only moves the flag — the class
        // deliberately keeps the 10s `toki query` timer idle for nobody.
        let aggregator = TokenAggregator()
        #expect(aggregator.isReportActive == false)

        aggregator.setReportActive(true)
        #expect(aggregator.isReportActive)
        aggregator.setReportActive(true)
        #expect(aggregator.isReportActive)

        aggregator.setReportActive(false)
        #expect(aggregator.isReportActive == false)
    }
}

/// The two range enums the aggregator reads. Pure, and each one decides a
/// query the app sends.
@Suite("Aggregator ranges")
struct AggregatorRangeTests {

    @Test("Every TimeRange has a bucket and a name")
    func timeRangeIsComplete() {
        #expect(TimeRange.allCases.count == 3)
        for range in TimeRange.allCases {
            #expect(!range.displayName.isEmpty)
            #expect(!range.queryBucket.isEmpty)
        }
    }

    @Test("The 30-minute range queries in 1h buckets on purpose")
    func thirtyMinutesUsesHourBucket() {
        // The daemon has no 30m bucket; asking for one returns nothing. The
        // narrowing to 30 minutes happens client-side in timeRangeCutoff.
        #expect(TimeRange.thirtyMinutes.queryBucket == "1h")
        #expect(TimeRange.oneHour.queryBucket == "1h")
        #expect(TimeRange.today.queryBucket == "1d")
    }

    @Test("TimeRange round-trips through its raw value")
    func timeRangeRoundTrips() {
        for range in TimeRange.allCases {
            #expect(TimeRange(rawValue: range.rawValue) == range)
        }
    }

    @Test("Each graph range's PromQL bucket is the width of its own bin")
    func bucketMatchesBinWidth() {
        // A bucket wider than the bin double-counts into neighbouring bins; a
        // narrower one leaves gaps. They have to agree.
        let expected: [GraphTimeRange: (TimeInterval, String)] = [
            .fiveMinutes: (10, "10s"),
            .tenMinutes: (20, "20s"),
            .thirtyMinutes: (60, "1m"),
            .oneHourGraph: (120, "2m"),
        ]
        for range in GraphTimeRange.allCases {
            let (interval, bucket) = try! #require(expected[range])
            #expect(range.sampleInterval == interval)
            #expect(range.promqlBucket == bucket)
        }
    }

    @Test("30 bins at the bin width is the window the graph asks for")
    func sinceCoversThirtyBins() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for range in GraphTimeRange.allCases {
            let stamp = range.sinceTimestamp
            #expect(stamp.count == 14, "\(range) produced \(stamp)")
            let date = try! #require(formatter.date(from: stamp))
            let ago = Date().timeIntervalSince(date)
            let expected = 31 * range.sampleInterval  // 30 bins + one bin of slack
            #expect(abs(ago - expected) < 5, "\(range): window was \(ago)s, expected ~\(expected)s")
        }
    }

    @Test("The graph window grows with the range, and never shrinks")
    func windowsAreOrdered() {
        let ordered: [GraphTimeRange] = [.fiveMinutes, .tenMinutes, .thirtyMinutes, .oneHourGraph]
        let widths = ordered.map(\.sampleInterval)
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count, "two ranges with the same bin width would be the same range")
    }
}
