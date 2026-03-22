import SwiftUI
import AppKit

extension ProviderInfo {
    /// Resolve colorName string to SwiftUI Color (Presentation layer only).
    var color: Color {
        Self.colorFromName(colorName)
    }

    /// Get color with optional custom override.
    func color(customColorName: String?) -> Color {
        Self.colorFromName(customColorName ?? colorName)
    }

    static func colorFromName(_ name: String) -> Color {
        switch name {
        case "orange": .orange
        case "blue": .blue
        case "green": .green
        case "gray": .gray
        case "purple": .purple
        case "red": .red
        case "pink": .pink
        case "yellow": .yellow
        case "teal": .teal
        case "indigo": .indigo
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        default: .secondary
        }
    }

    static func nsColorFromName(_ name: String) -> NSColor {
        switch name {
        case "orange": .systemOrange
        case "blue": .systemBlue
        case "green": .systemGreen
        case "gray": .systemGray
        case "purple": .systemPurple
        case "red": .systemRed
        case "pink": .systemPink
        case "yellow": .systemYellow
        case "teal": .systemTeal
        case "indigo": .systemIndigo
        case "mint": .systemMint
        case "cyan": .systemCyan
        case "brown": .systemBrown
        default: .labelColor
        }
    }

    /// All available color names for the color picker.
    @MainActor static var availableColors: [(name: String, displayName: String)] {
        [
            ("orange", L.color.orange),
            ("blue", L.color.blue),
            ("green", L.color.green),
            ("purple", L.color.purple),
            ("red", L.color.red),
            ("pink", L.color.pink),
            ("yellow", L.color.yellow),
            ("teal", L.color.teal),
            ("indigo", L.color.indigo),
            ("mint", L.color.mint),
            ("cyan", L.color.cyan),
            ("brown", L.color.brown),
            ("gray", L.color.gray),
        ]
    }
}
