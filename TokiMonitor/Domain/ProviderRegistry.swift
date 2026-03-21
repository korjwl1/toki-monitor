import Foundation

/// Metadata for an AI provider, driven by model name prefixes and toki schema names.
struct ProviderInfo: Identifiable {
    let id: String           // canonical name
    let name: String
    let prefixes: [String]   // model name prefixes
    let schemas: [String]    // toki schema names (e.g., "claude_code", "codex")
    let icon: String         // SF Symbol name
    let colorName: String    // resolved to Color in Presentation layer

    func matches(model: String) -> Bool {
        let lower = model.lowercased()
        return prefixes.contains { lower.hasPrefix($0) }
    }

    func matchesSchema(_ schema: String) -> Bool {
        schemas.contains(schema)
    }

    /// The toki settings provider ID (first schema name).
    var tokiProviderId: String? {
        schemas.first
    }
}

/// Maps model names and toki schemas to providers. Data-driven, no hardcoded UI logic.
struct ProviderRegistry {
    static let providers: [ProviderInfo] = [
        ProviderInfo(
            id: "anthropic",
            name: "Claude",
            prefixes: ["claude-", "claude_"],
            schemas: ["claude_code"],
            icon: "brain.head.profile",
            colorName: "orange"
        ),
        ProviderInfo(
            id: "openai",
            name: "OpenAI",
            prefixes: ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"],
            schemas: ["codex"],
            icon: "circle.hexagongrid",
            colorName: "green"
        ),
        ProviderInfo(
            id: "google",
            name: "Gemini",
            prefixes: ["gemini-", "gemini_"],
            schemas: ["gemini_cli"],
            icon: "sparkle",
            colorName: "blue"
        ),
    ]

    static let unknown = ProviderInfo(
        id: "unknown",
        name: "Other",
        prefixes: [],
        schemas: [],
        icon: "questionmark.circle",
        colorName: "gray"
    )

    /// All known providers (excluding unknown).
    static let allProviders: [ProviderInfo] = providers

    /// Providers available for user configuration (currently supported only).
    static let configurableProviders: [ProviderInfo] = providers.filter {
        // Gemini not yet supported by toki
        $0.id != "google"
    }

    /// Resolve a model name to its provider.
    static func resolve(model: String) -> ProviderInfo {
        providers.first { $0.matches(model: model) } ?? unknown
    }

    /// Resolve a toki schema name to its provider.
    static func resolveSchema(_ schema: String) -> ProviderInfo {
        providers.first { $0.matchesSchema(schema) } ?? unknown
    }
}
