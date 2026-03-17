import Foundation

enum AnimationState: Int, Comparable {
    case idle = 0     // 0 tokens/min
    case low = 1      // 1-100 tokens/min
    case medium = 2   // 100-1000 tokens/min
    case high = 3     // 1000+ tokens/min

    static func < (lhs: AnimationState, rhs: AnimationState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Frames per second for character animation at this state.
    var characterFPS: Double {
        switch self {
        case .idle: 0
        case .low: 2
        case .medium: 6
        case .high: 12
        }
    }
}

enum AnimationStyle: String, CaseIterable, Codable {
    case character   // Frame-based character animation
    case numeric     // "1.2K/m" text display
    case sparkline   // Mini graph
}

/// Maps token throughput rate to animation state.
struct AnimationStateMapper {
    var lowThreshold: Double = 1        // tokens/min
    var mediumThreshold: Double = 100   // tokens/min
    var highThreshold: Double = 1000    // tokens/min

    func map(tokensPerMinute: Double) -> AnimationState {
        if tokensPerMinute < lowThreshold {
            return .idle
        } else if tokensPerMinute < mediumThreshold {
            return .low
        } else if tokensPerMinute < highThreshold {
            return .medium
        } else {
            return .high
        }
    }
}
