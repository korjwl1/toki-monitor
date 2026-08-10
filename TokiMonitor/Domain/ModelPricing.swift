import Foundation

/// Client-side cost estimation for models when the CLI PromQL query
/// path does not include `cost_usd` in its output.
///
/// Prices are per-token (not per-million-tokens) for direct multiplication.
/// Source: Official API pricing pages as of 2025-Q4. Updated periodically.
///
/// # What a cost number means here
///
/// "Valued at the prices we currently know" — NOT "what was billed at the
/// time". Neither side stores a price history: the daemon values events with
/// whatever LiteLLM snapshot it last downloaded (`toki/src/pricing.rs`), and
/// this table is compiled into the app. So a chart of last month's cost
/// changes when either table changes, and the same event can be valued
/// differently by the two of them.
///
/// That is a deliberate choice, not an oversight: billed-at-the-time costs
/// would need effective-dated prices recorded per event, which nothing in the
/// pipeline captures.
///
/// # Where the prices come from
///
/// The daemon's own LiteLLM cache first (`~/.config/toki/pricing.json`), so
/// this app and the daemon quote the same number. That file turned out to be
/// comprehensive and current — it already listed Opus 5, Fable 5 and Sonnet
/// 5's introductory price — which makes the table below a genuine last resort
/// for a machine with no daemon cache yet, not the main path it was written
/// as. When both end up pricing one series, `FrameAdapter` says so.
enum ModelPricing {
    struct Pricing {
        let inputPerToken: Double
        let outputPerToken: Double
        let cacheWritePerToken: Double?
        let cacheReadPerToken: Double?
    }

    /// Per-million-token prices converted to per-token, from Anthropic's
    /// published table. `reviewedOn` below says when they were last checked.
    ///
    /// Deliberately NO family catch-all. The daemon matches model names
    /// exactly and omits `cost_usd` when it has no entry
    /// (`toki/src/pricing.rs`: "Exact model name match only — no fuzzy
    /// matching to avoid mismatched pricing"). This table used to end in a
    /// `claude-` entry that caught everything else at Sonnet prices, which
    /// made the fallback confidently wrong in exactly the window it exists
    /// for: a model so new that LiteLLM has no price for it yet. An unknown
    /// model now yields nil, and the cost column stays absent.
    private static let pricingTable: [(prefix: String, pricing: Pricing)] = [
        // Anthropic — longest prefix wins, so `claude-opus-4-5` is not
        // swallowed by `claude-opus-4` (that bug priced Opus 4.5 through 4.8
        // at the retired 4.1 rate, three times over).
        ("claude-fable-5",   anthropic(input: 10, output: 50)),
        ("claude-mythos-5",  anthropic(input: 10, output: 50)),
        ("claude-opus-5",    anthropic(input: 5, output: 25)),
        ("claude-opus-4-8",  anthropic(input: 5, output: 25)),
        ("claude-opus-4-7",  anthropic(input: 5, output: 25)),
        ("claude-opus-4-6",  anthropic(input: 5, output: 25)),
        ("claude-opus-4-5",  anthropic(input: 5, output: 25)),
        // Retired, but old events still carry the name and were billed at it.
        ("claude-opus-4-1",  anthropic(input: 15, output: 75)),
        ("claude-opus-4",    anthropic(input: 15, output: 75)),
        // Introductory pricing through 2026-08-31; $3/$15 from 2026-09-01.
        // `sonnetFiveIntroductoryPricingEnds` below is asserted by a test so
        // this cannot be forgotten.
        ("claude-sonnet-5",  anthropic(input: 2, output: 10)),
        ("claude-sonnet-4-6", anthropic(input: 3, output: 15)),
        ("claude-sonnet-4-5", anthropic(input: 3, output: 15)),
        ("claude-sonnet-4",  anthropic(input: 3, output: 15)),
        ("claude-3-7-sonnet", anthropic(input: 3, output: 15)),
        ("claude-3-5-sonnet", anthropic(input: 3, output: 15)),
        ("claude-haiku-4-5", anthropic(input: 1, output: 5)),
        ("claude-3-5-haiku", anthropic(input: 0.80, output: 4)),
        ("claude-3-haiku",   anthropic(input: 0.25, output: 1.25)),
        // OpenAI / Google — no cache-tier pricing modelled, and no catch-all:
        // a model absent here costs nothing rather than something invented.
        ("gpt-4o", Pricing(
            inputPerToken: 2.50 / 1_000_000,
            outputPerToken: 10.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 1.25 / 1_000_000
        )),
        ("gpt-4-turbo", Pricing(
            inputPerToken: 10.0 / 1_000_000,
            outputPerToken: 30.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
        ("o3", Pricing(
            inputPerToken: 2.0 / 1_000_000,
            outputPerToken: 8.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 0.50 / 1_000_000
        )),
        ("o1", Pricing(
            inputPerToken: 15.0 / 1_000_000,
            outputPerToken: 60.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: 7.50 / 1_000_000
        )),
        ("gemini-2.0-flash", Pricing(
            inputPerToken: 0.10 / 1_000_000,
            outputPerToken: 0.40 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
        ("gemini-1.5-pro", Pricing(
            inputPerToken: 1.25 / 1_000_000,
            outputPerToken: 5.0 / 1_000_000,
            cacheWritePerToken: nil,
            cacheReadPerToken: nil
        )),
    ]

    /// Anthropic's cache tiers are fixed multiples of the base input price
    /// (5-minute write 1.25x, cache hit 0.1x), so spelling them out per model
    /// would be four chances to mistype the same two ratios.
    private static func anthropic(input: Double, output: Double) -> Pricing {
        Pricing(
            inputPerToken: input / 1_000_000,
            outputPerToken: output / 1_000_000,
            cacheWritePerToken: input * 1.25 / 1_000_000,
            cacheReadPerToken: input * 0.1 / 1_000_000
        )
    }

    /// When these prices were last checked against the published table.
    /// A hand-maintained table with no freshness marker is one nobody can
    /// tell is stale.
    static let reviewedOn = "2026-08-10"

    /// Sonnet 5 runs on introductory pricing ($2/$10) until this date, then
    /// moves to $3/$15. Encoded because "current prices" is the semantic this
    /// table promises, and a scheduled change is not a surprise.
    static let sonnetFiveIntroductoryPricingEnds = "2026-09-01"

    /// Fallback multipliers for Anthropic Fast mode. Mirrors toki's
    /// `providers/claude_code::FAST_MULTIPLIER` so client-side and
    /// server-side cost estimates agree when the CLI omits `cost_usd`.
    ///
    /// Fast mode is $10/$50 against a $5/$25 base — a flat 2x, and because
    /// the cache tiers are multiples of the base input price the same 2x
    /// carries them correctly. It is offered on Opus 5 and Opus 4.8 only:
    /// 4.7 rejects the request and 4.6 runs at standard speed and standard
    /// rates, so neither takes a multiplier.
    private static let fastMultiplier: [String: Double] = [
        "claude-opus-5": 2.0,
        "claude-opus-4-8": 2.0,
    ]

    // MARK: - The daemon's own table

    /// Where the daemon caches the LiteLLM price list
    /// (`toki/src/pricing.rs::default_cache_path`).
    static let daemonCachePath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/toki/pricing.json")

    private struct DaemonCacheFile: Decodable {
        struct Entry: Decodable {
            let input_cost_per_token: Double
            let output_cost_per_token: Double
            let cache_creation_input_token_cost: Double?
            let cache_read_input_token_cost: Double?
        }
        let prices: [String: Entry]
    }

    private struct LoadedCache {
        let prices: [String: Pricing]
        let modified: Date?
    }

    private static let cacheLock = NSLock()
    /// Keyed by path so tests can use their own file without disturbing the
    /// real one — the suite runs in parallel, and a mutable global path would
    /// have tests overwriting each other's answers.
    nonisolated(unsafe) private static var loadedCaches: [String: LoadedCache] = [:]

    /// Which table a number came from. The two can disagree, so a caller that
    /// mixes them in one series needs to be able to say so.
    enum Source: Equatable, Sendable {
        /// The daemon's LiteLLM cache — the same prices the daemon itself used.
        case daemonTable
        /// The table compiled into this app.
        case compiledFallback
    }

    struct Estimate: Equatable, Sendable {
        let cost: Double
        let source: Source
    }

    /// Read the daemon's cache, re-reading when it changes on disk so a
    /// price refresh reaches a running app without a restart.
    ///
    /// This is the same machine and the same product, and the file is always
    /// fresher than a table compiled months ago — LiteLLM already carried
    /// Opus 5, Fable 5 and Sonnet 5's introductory price while the compiled
    /// table had none of them. Keeping a second source of truth here only
    /// created a way to disagree with the daemon.
    private static func daemonPricing(for model: String, at path: URL) -> Pricing? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let key = path.path
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: key)[.modificationDate] as? Date) ?? nil

        if let loaded = loadedCaches[key], loaded.modified == modified {
            return loaded.prices[model]
        }

        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(DaemonCacheFile.self, from: data)
        else {
            // Remember the miss too, so a missing file is not re-stat'd and
            // re-read on every single summary.
            loadedCaches[key] = LoadedCache(prices: [:], modified: modified)
            return nil
        }
        let prices = file.prices.mapValues {
            Pricing(inputPerToken: $0.input_cost_per_token,
                    outputPerToken: $0.output_cost_per_token,
                    cacheWritePerToken: $0.cache_creation_input_token_cost,
                    cacheReadPerToken: $0.cache_read_input_token_cost)
        }
        loadedCaches[key] = LoadedCache(prices: prices, modified: modified)
        return prices[model]
    }

    // MARK: - Estimation

    /// Estimate cost from token breakdown. Returns nil if model is unknown.
    static func estimateCost(
        model: String,
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheCreationInputTokens: UInt64? = nil,
        cacheReadInputTokens: UInt64? = nil,
        cachedInputTokens: UInt64? = nil,
        cachePath: URL = daemonCachePath
    ) -> Double? {
        estimate(model: model, inputTokens: inputTokens, outputTokens: outputTokens,
                 cacheCreationInputTokens: cacheCreationInputTokens,
                 cacheReadInputTokens: cacheReadInputTokens,
                 cachedInputTokens: cachedInputTokens,
                 cachePath: cachePath)?.cost
    }

    /// The same estimate, with the table it came from.
    ///
    /// `cachePath` exists so a test can supply its own price file; the app
    /// always uses the default.
    static func estimate(
        model: String,
        inputTokens: UInt64,
        outputTokens: UInt64,
        cacheCreationInputTokens: UInt64? = nil,
        cacheReadInputTokens: UInt64? = nil,
        cachedInputTokens: UInt64? = nil,
        cachePath: URL = daemonCachePath
    ) -> Estimate? {
        let lower = model.lowercased()

        // Anthropic Fast mode: upstream toki appends "-fast" to the model name
        // when message.usage.speed == "fast". The fallback pricing table only
        // knows base model prefixes, so strip the suffix and apply a multiplier
        // at the end to keep client-side and server-side estimates aligned.
        var lookup = lower
        var multiplier = 1.0
        if lookup.hasSuffix("-fast") {
            let base = String(lookup.dropLast(5))
            if let mul = fastMultiplier[base] {
                lookup = base
                multiplier = mul
            }
        }

        // The daemon's own table first, matched exactly the way the daemon
        // matches it. Only when it has nothing does the compiled table get a
        // turn, and then by longest prefix — it lists `claude-opus-4` for the
        // retired model and `claude-opus-4-5` for the current one, and
        // first-match would give every 4.x the retired price.
        let resolved: (pricing: Pricing, source: Source)
        if let fromDaemon = daemonPricing(for: lookup, at: cachePath) {
            resolved = (fromDaemon, .daemonTable)
        } else if let fromTable = pricingTable
            .filter({ lookup.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count })?.pricing {
            resolved = (fromTable, .compiledFallback)
        } else {
            return nil
        }
        let pricing = resolved.pricing

        var cost = 0.0

        // Cache write tokens (billed at cache write rate, not input rate)
        if let cacheWrite = cacheCreationInputTokens, cacheWrite > 0,
           let cacheWritePrice = pricing.cacheWritePerToken {
            cost += Double(cacheWrite) * cacheWritePrice
        }

        // Cache read tokens (billed at discounted rate)
        let cacheRead = (cacheReadInputTokens ?? 0) + (cachedInputTokens ?? 0)
        if cacheRead > 0, let cacheReadPrice = pricing.cacheReadPerToken {
            cost += Double(cacheRead) * cacheReadPrice
        }

        // Regular input tokens (excluding cache tokens which are billed separately)
        cost += Double(inputTokens) * pricing.inputPerToken

        // Output tokens
        cost += Double(outputTokens) * pricing.outputPerToken

        return Estimate(cost: cost * multiplier, source: resolved.source)
    }
}
