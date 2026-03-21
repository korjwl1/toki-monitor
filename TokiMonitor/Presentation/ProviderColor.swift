import SwiftUI

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

    /// All available color names for the color picker.
    static let availableColors: [(name: String, displayName: String)] = [
        ("orange", "주황"),
        ("blue", "파랑"),
        ("green", "초록"),
        ("purple", "보라"),
        ("red", "빨강"),
        ("pink", "분홍"),
        ("yellow", "노랑"),
        ("teal", "청록"),
        ("indigo", "남색"),
        ("mint", "민트"),
        ("cyan", "시안"),
        ("brown", "갈색"),
        ("gray", "회색"),
    ]
}
