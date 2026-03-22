import AppKit
import UserNotifications

@main
enum TokiMonitorApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip setup when running as test host
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }

        // Enable liquid glass in non-activating panels
        GlassFixWorkaround.install()

        statusBarController = StatusBarController()

        // Request notification permission for usage alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // When Dock icon is clicked to quit, just close windows and hide from Dock
        // instead of terminating (menu bar app should keep running)
        if NSApp.activationPolicy() == .regular {
            for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
                window.close()
            }
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        return .terminateNow
    }
}
