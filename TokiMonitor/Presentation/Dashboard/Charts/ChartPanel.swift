import SwiftUI

/// Panel wrapper for charts with system-native styling.
struct ChartPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            content
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}
