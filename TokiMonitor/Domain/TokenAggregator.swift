import Foundation

/// Aggregates token events for rate calculation and recent history.
@MainActor
@Observable
final class TokenAggregator {
    private(set) var tokensPerMinute: Double = 0
    private(set) var animationState: AnimationState = .idle
    private(set) var recentHistory: [Double] = []  // last N rate samples for sparkline

    private var events: [(date: Date, tokens: UInt64)] = []
    private let rateWindow: TimeInterval = 30  // seconds for rate calc
    private let historySize = 30  // number of sparkline data points
    private let mapper = AnimationStateMapper()
    private var sampleTimer: Timer?

    /// Call when a new token event arrives.
    func addEvent(_ event: TokenEvent) {
        let total = event.inputTokens + event.outputTokens
        events.append((date: event.receivedAt, tokens: total))
        pruneOldEvents()
        recalculateRate()
    }

    /// Start periodic sampling for sparkline history.
    func startSampling() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleRate()
            }
        }
    }

    func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    // MARK: - Private

    private func pruneOldEvents() {
        let cutoff = Date().addingTimeInterval(-rateWindow)
        events.removeAll { $0.date < cutoff }
    }

    private func recalculateRate() {
        pruneOldEvents()
        let totalTokens = events.reduce(UInt64(0)) { $0 + $1.tokens }
        let minutes = rateWindow / 60.0
        tokensPerMinute = Double(totalTokens) / minutes
        animationState = mapper.map(tokensPerMinute: tokensPerMinute)
    }

    private func sampleRate() {
        recalculateRate()
        recentHistory.append(tokensPerMinute)
        if recentHistory.count > historySize {
            recentHistory.removeFirst(recentHistory.count - historySize)
        }
    }

    /// Format tokens/min for display (e.g., "1.2K/m", "0/m").
    nonisolated static func formatRate(_ tokensPerMinute: Double) -> String {
        if tokensPerMinute < 1 {
            return "0/m"
        } else if tokensPerMinute < 1000 {
            return "\(Int(tokensPerMinute))/m"
        } else if tokensPerMinute < 1_000_000 {
            return String(format: "%.1fK/m", tokensPerMinute / 1000)
        } else {
            return String(format: "%.1fM/m", tokensPerMinute / 1_000_000)
        }
    }
}
