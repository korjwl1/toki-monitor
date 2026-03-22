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
        window.title = "TokiMonitor"
        window.contentViewController = hostingController
        window.center()
        window.setFrameAutosaveName("TokiDashboard")
        window.minSize = NSSize(width: 800, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = windowDelegate
        window.makeKeyAndOrderFront(nil)

        // Show in Dock while dashboard is open
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    // MARK: - Window Delegate

    private lazy var windowDelegate = DashboardWindowDelegate { [weak self] in
        self?.window = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private final class DashboardWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
