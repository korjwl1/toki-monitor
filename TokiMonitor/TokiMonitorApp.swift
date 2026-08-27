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

        // Install the standard app + Edit main menu. Without this,
        // NSTextField inside the dashboard window doesn't receive
        // Cmd+A / Cmd+C / Cmd+X / Cmd+V / Cmd+Z — macOS routes those
        // keystrokes through menu key equivalents, and a menu-bar app
        // (`.accessory` at boot) ships with `NSApp.mainMenu == nil`.
        NSApp.mainMenu = Self.makeMainMenu()

        // Enable liquid glass in non-activating panels
        GlassFixWorkaround.install()

        statusBarController = StatusBarController()

        // Request notification permission for usage alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Monitor settings sync, if the user opted in. Does nothing at all
        // otherwise — the switch is off in a fresh installation.
        MonitorSyncController.shared.start()
    }

    /// Build a minimal NSMainMenu: the macOS-required application menu
    /// (Hide / Quit / etc.) and a standard Edit menu so text fields
    /// in any window respond to Cmd+A/C/X/V/Z out of the box.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu — title is overridden by the system with the
        // bundle name, but we still need the menu item present so
        // NSApp knows which submenu is the "application" one.
        let appName = ProcessInfo.processInfo.processName
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — standard items wired to the responder-chain
        // selectors that NSTextField implements. Adding them here is
        // what makes Cmd+A actually trigger `selectAll(_:)` on the
        // focused text field.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo",
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete",
                         action: #selector(NSText.delete(_:)),
                         keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
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
