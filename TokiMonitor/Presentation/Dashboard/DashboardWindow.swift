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
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("TokiDashboard")
        window.minSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
