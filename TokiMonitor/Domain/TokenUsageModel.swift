import Foundation

/// Provider-agnostic protocol for displaying token usage.
protocol TokenUsageModel {
    var displayName: String { get }
    var totalInput: UInt64 { get }
    var totalOutput: UInt64 { get }
    var estimatedCost: Double? { get }
    var eventCount: Int { get }
}
