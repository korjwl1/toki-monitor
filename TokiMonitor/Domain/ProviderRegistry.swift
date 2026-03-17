import SwiftUI

/// Metadata for an AI provider, driven by model name prefixes.
struct ProviderInfo: Identifiable {
    let id: String       // canonical name
    let name: String
    let prefixes: [String]
    let icon: String     // SF Symbol
    let color: Color

    func matches(model: String) -> Bool {
        let lower = model.lowercased()
        return prefixes.contains { lower.hasPrefix($0) }
    }
}

/// Maps model names to providers. Data-driven, no hardcoded UI logic.
struct ProviderRegistry {
    static let providers: [ProviderInfo] = [
        ProviderInfo(
            id: "anthropic",
            name: "Claude",
            prefixes: ["claude-", "claude_"],
            icon: "brain.head.profile",
            color: .orange
        ),
        ProviderInfo(
            id: "google",
            name: "Gemini",
            prefixes: ["gemini-", "gemini_"],
            icon: "sparkle",
            color: .blue
        ),
        ProviderInfo(
            id: "openai",
            name: "OpenAI",
            prefixes: ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"],
            icon: "circle.hexagongrid",
            color: .green
        ),
    ]

    static let unknown = ProviderInfo(
        id: "unknown",
        name: "Other",
        prefixes: [],
        icon: "questionmark.circle",
        color: .gray
    )

    /// Resolve a model name to its provider.
    static func resolve(model: String) -> ProviderInfo {
        providers.first { $0.matches(model: model) } ?? unknown
    }
}
