import Foundation

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // Frame-based character animation
    case numeric     // "1.2K/m" text display
    case sparkline   // Mini graph
}

/// Maps token throughput rate to a continuous animation interval.
///
/// Uses log scale calibrated to actual observed rates:
///   - idle (< 10K tok/m): no animation
///   - start (~10K tok/m): 5.0 FPS — smooth minimum (below this, frames stutter)
///   - light (~500K tok/m): 6.5 FPS — brisk trot
///   - median (~2.2M tok/m): 8.0 FPS — running
///   - peak (~5M tok/m): 9.0 FPS — fast run
///   - heavy (8x, ~40M tok/m): 14 FPS — full sprint
struct AnimationStateMapper {
    private let slowInterval: TimeInterval = 0.20   // 5 FPS minimum (smooth for 7-frame cycle)
    private let fastInterval: TimeInterval = 0.06   // ~16 FPS max
    private let minRate: Double = 10000             // below = idle
    private let maxRate: Double = 50000000          // 8x heavy user peak

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
