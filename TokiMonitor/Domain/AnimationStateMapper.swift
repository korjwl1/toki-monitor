import Foundation

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // Frame-based character animation
    case numeric     // "1.2K/m" text display
    case sparkline   // Mini graph
}

/// Maps token throughput rate to a continuous animation interval.
///
/// Uses log scale for wide dynamic range (10 tok/m to 100K+ tok/m):
///   - idle (< 10 tok/m): no animation (sleeping rabbit)
///   - low (~10 tok/m): ~0.5s/frame → ~2 FPS — gentle stroll
///   - mid (~1K tok/m): ~0.28s/frame → ~3.6 FPS — brisk trot
///   - high (~10K tok/m): ~0.16s/frame → ~6 FPS — running
///   - sprint (~50K+ tok/m): ~0.05s/frame → ~20 FPS — full sprint
struct AnimationStateMapper {
    private let slowInterval: TimeInterval = 0.50   // slowest frame interval
    private let fastInterval: TimeInterval = 0.05   // fastest frame interval
    private let minRate: Double = 10                // below = idle
    private let maxRate: Double = 1000000            // clamp ceiling (~$30/m for Opus)

    func isIdle(tokensPerMinute: Double) -> Bool {
        tokensPerMinute < minRate
    }

    /// Returns per-frame interval. 0 means idle (no animation).
    func interval(for tokensPerMinute: Double) -> TimeInterval {
        guard !isIdle(tokensPerMinute: tokensPerMinute) else { return 0 }

        // Log scale: spreads the 10 → 100K range evenly for visible speed changes.
        // Linear scale would saturate at ~2K tok/m, making 2K and 50K look identical.
        let clamped = min(max(tokensPerMinute, minRate), maxRate)
        let t = (log10(clamped) - log10(minRate)) / (log10(maxRate) - log10(minRate))

        // Lerp between slow and fast
        return slowInterval - t * (slowInterval - fastInterval)
    }
}
