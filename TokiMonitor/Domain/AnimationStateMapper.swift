import Foundation

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // Frame-based character animation
    case numeric     // "1.2K/m" text display
    case sparkline   // Mini graph
}

/// Maps token throughput rate to a continuous animation interval.
///
/// Uses log scale for wide dynamic range (1K to 5M tok/m):
///   - idle (< 1K tok/m): no animation (sleeping rabbit)
///   - light (~5K tok/m): ~0.38s/frame → ~2.6 FPS — gentle stroll
///   - active (~200K tok/m): ~0.21s/frame → ~4.7 FPS — brisk trot
///   - normal (~750K tok/m): ~0.16s/frame → ~6.5 FPS — running
///   - sprint (~3M+ tok/m): ~0.08s/frame → ~12 FPS — full sprint
struct AnimationStateMapper {
    private let slowInterval: TimeInterval = 0.45   // slowest frame interval
    private let fastInterval: TimeInterval = 0.07   // fastest frame interval
    private let minRate: Double = 1000              // below = idle
    private let maxRate: Double = 5000000           // clamp ceiling (peak burst)

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
