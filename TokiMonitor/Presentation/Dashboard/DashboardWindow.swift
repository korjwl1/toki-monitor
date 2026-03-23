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

        // Size to ~55% of screen area (√0.55 ≈ 74% each dimension)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale: CGFloat = 0.74
        let initialWidth = max(800, screen.width * scale)
        let initialHeight = max(600, screen.height * scale)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "TokiMonitor"
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 800, height: 600)
        window.setFrameAutosaveName("TokiDashboard")
        // setFrameAutosaveName restores saved frame. If no saved frame, apply computed size.
        if UserDefaults.standard.string(forKey: "NSWindow Frame TokiDashboard") == nil {
            window.setContentSize(NSSize(width: initialWidth, height: initialHeight))
        }
        window.center()
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
