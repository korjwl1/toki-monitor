import Foundation

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // Frame-based character animation
    case numeric     // "1.2K/m" text display
    case sparkline   // Mini graph
}

/// Maps token throughput rate to a continuous animation interval,
/// inspired by menubar_runcat's CPU-proportional speed formula.
///
/// Speed range for 7-frame character (one full cycle):
///   - idle (0 tok/m): no animation
///   - low (~10 tok/m): ~0.35s/frame → ~2 FPS, full cycle ~2.5s — gentle stroll
///   - mid (~500 tok/m): ~0.15s/frame → ~7 FPS, full cycle ~1s — brisk trot
///   - high (~2000+ tok/m): ~0.1s/frame → ~10 FPS, full cycle ~0.7s — sprint
struct AnimationStateMapper {
    private let slowInterval: TimeInterval = 0.35   // slowest frame interval
    private let fastInterval: TimeInterval = 0.10   // fastest frame interval
    private let maxRate: Double = 2000              // clamp ceiling
    private let idleThreshold: Double = 1           // below = idle

    func isIdle(tokensPerMinute: Double) -> Bool {
        tokensPerMinute < idleThreshold
    }

    /// Returns per-frame interval. 0 means idle (no animation).
    func interval(for tokensPerMinute: Double) -> TimeInterval {
        guard !isIdle(tokensPerMinute: tokensPerMinute) else { return 0 }

        // Normalize rate to 0...1 range
        let clamped = min(tokensPerMinute, maxRate)
        let t = (clamped - idleThreshold) / (maxRate - idleThreshold)

        // Ease-out curve so it ramps up quickly at low rates
        // then flattens toward sprint speed
        let eased = 1 - pow(1 - t, 2)

        // Lerp between slow and fast
        return slowInterval - eased * (slowInterval - fastInterval)
    }
}
