import SwiftUI

/// Unified design system based on 8pt grid + modular scale 1.125.
enum DS {
    // MARK: - Spacing (8pt grid)
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    // MARK: - Typography (modular scale 1.125 — compact UI)
    static let fontTitle: CGFloat = 14
    static let fontBody: CGFloat = 12
    static let fontCaption: CGFloat = 10
    static let fontTiny: CGFloat = 9

    // MARK: - Border Radius (nested: inner = outer - padding)
    static let panelRadius: CGFloat = 14
    static let widgetRadius: CGFloat = 10   // 14 - 4(gap)
    static let btnRadius: CGFloat = 8

    // MARK: - Colors
    static let dividerColor = Color.primary.opacity(0.1)

    // MARK: - Menu Bar
    enum Menu {
        static let leftWidth: CGFloat = 200
        static let rightWidth: CGFloat = 56
        static let btnSize: CGFloat = 56
        static let chartHeight: CGFloat = 32
    }

    // MARK: - Dashboard
    enum Dashboard {
        static let gridPadding: CGFloat = 16
        static let gridSpacing: CGFloat = 8
        static let panelTitleFont: CGFloat = 13
    }
}
