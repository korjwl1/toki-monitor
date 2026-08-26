import Foundation

/// Metadata for an AI provider, driven by model name prefixes and toki schema names.
struct ProviderInfo: Identifiable {
    let id: String           // canonical name
    let name: String
    let prefixes: [String]   // model name prefixes
    let schemas: [String]    // toki schema names (e.g., "claude_code", "codex")
    let icon: String         // SF Symbol name (fallback)
    let logoImage: String?   // Asset Catalog image name (preferred)
    let colorName: String    // resolved to Color in Presentation layer
    /// What the user calls the TOOL, as opposed to `name`, which is the
    /// vendor. "Claude Code" and "Codex" are what appears in toki's schemas
    /// and in the plan-fit page; "Claude" and "OpenAI" are who makes them.
    /// Both are legitimate, which is why they live together rather than in two
    /// separate tables that agree until someone edits one of them.
    let toolName: String

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
            logoImage: "claude-logo",
            colorName: "orange",
            toolName: "Claude Code"
        ),
        ProviderInfo(
            id: "openai",
            name: "OpenAI",
            prefixes: ["gpt-", "o1-", "o3-", "o4-", "chatgpt-"],
            schemas: ["codex"],
            icon: "circle.hexagongrid",
            logoImage: "openai-logo",
            colorName: "green",
            toolName: "Codex"
        ),
        ProviderInfo(
            id: "google",
            name: "Gemini",
            prefixes: ["gemini-", "gemini_"],
            schemas: ["gemini_cli"],
            icon: "sparkle",
            logoImage: nil,
            colorName: "blue",
            toolName: "Gemini CLI"
        ),
    ]

    static let unknown = ProviderInfo(
        id: "unknown",
        name: "Other",
        prefixes: [],
        schemas: [],
        icon: "questionmark.circle",
        logoImage: nil,
        colorName: "gray",
        toolName: "Other"
    )

    /// The tool name for a toki schema (`"claude_code"` → `"Claude Code"`).
    ///
    /// One table. `PlanFitStyle.providerTitle` used to carry its own copy of
    /// this mapping, which meant two places had to agree about what a schema
    /// is called and only comments held them together.
    static func toolTitle(forSchema schema: String) -> String {
        providers.first { $0.matchesSchema(schema) }?.toolName ?? schema
    }

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
