import AppKit
import SwiftUI

/// Manages the dashboard window lifecycle.
@MainActor
final class DashboardWindowController {
    private var window: NSWindow?
    private let reportClient: TokiReportClient

    init(reportClient: TokiReportClient = TokiReportClient()) {
        self.reportClient = reportClient
    }

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let dashboardView = DashboardView(reportClient: reportClient)
        let hostingController = NSHostingController(rootView: dashboardView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Toki Monitor — Dashboard"
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("TokiDashboard")
        window.minSize = NSSize(width: 500, height: 400)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
