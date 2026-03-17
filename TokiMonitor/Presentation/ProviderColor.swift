import SwiftUI

extension ProviderInfo {
    /// Resolve colorName string to SwiftUI Color (Presentation layer only).
    var color: Color {
        switch colorName {
        case "orange": .orange
        case "blue": .blue
        case "green": .green
        case "gray": .gray
        case "purple": .purple
        case "red": .red
        default: .secondary
        }
    }
}
