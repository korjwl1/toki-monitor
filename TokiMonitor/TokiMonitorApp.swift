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
}
