import Foundation

/// Shared formatting utilities for token counts and costs.
/// Used across Popover, Dashboard, and Menu Bar views.
enum TokenFormatter {
    static func formatTokens(_ count: UInt64) -> String {
        if count < 1000 {
            return "\(count)"
        } else if count < 1_000_000 {
            return String(format: "%.1fK", Double(count) / 1000)
        } else {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else if cost < 1 {
            return String(format: "$%.3f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }

    static func formatRate(_ tokensPerMinute: Double) -> String {
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

    /// Unit-aware rate formatting.
    static func formatRate(_ tokensPerMinute: Double, unit: TokenUnit) -> String {
        switch unit {
        case .perMinute:
            return formatRate(tokensPerMinute)
        case .perSecond:
            let tps = tokensPerMinute / 60.0
            if tps < 0.1 { return "0/s" }
            else if tps < 1000 { return String(format: "%.0f/s", tps) }
            else if tps < 1_000_000 { return String(format: "%.1fK/s", tps / 1000) }
            else { return String(format: "%.1fM/s", tps / 1_000_000) }
        case .raw:
            let total = UInt64(max(0, tokensPerMinute * 0.5))  // 30s window estimate
            return formatTokens(total)
        }
    }
}
