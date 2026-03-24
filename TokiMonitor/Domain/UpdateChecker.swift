import AppKit

/// Checks for app updates via Homebrew and shows a native alert dialog.
@MainActor
final class UpdateChecker {
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"
    private static let checkIntervalKey = "lastUpdateCheckDate"

    private let currentVersion: String

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check on launch. Skips if already checked within 24 hours.
    func checkOnLaunch() {
        let defaults = UserDefaults.standard
        if let lastCheck = defaults.object(forKey: Self.checkIntervalKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return // checked within 24h
        }

        Task {
            await checkAndPrompt()
        }
    }

    /// Force check (e.g. from settings button).
    func checkNow() {
        Task {
            await checkAndPrompt(force: true)
        }
    }

    private func checkAndPrompt(force: Bool = false) async {
        UserDefaults.standard.set(Date(), forKey: Self.checkIntervalKey)

        guard let latest = await fetchLatestBrewVersion() else { return }
        guard isNewerStable(latest: latest, current: currentVersion) else {
            if force {
                showUpToDateAlert()
            }
            return
        }

        // Don't nag about the same version (unless force)
        let lastNotified = UserDefaults.standard.string(forKey: Self.lastNotifiedKey)
        if !force && lastNotified == latest { return }

        UserDefaults.standard.set(latest, forKey: Self.lastNotifiedKey)
        showUpdateAlert(version: latest)
    }

    // MARK: - Alerts

    private func showUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = L.tr(
            "Toki Monitor \(version) 업데이트 가능",
            "Toki Monitor \(version) Available"
        )
        alert.informativeText = L.tr(
            "새 버전이 있습니다. 터미널에서 업데이트 명령어를 실행하세요.",
            "A new version is available. Run the update command in Terminal."
        )
        alert.alertStyle = .informational
        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }

        alert.addButton(withTitle: L.tr("업데이트", "Update"))
        alert.addButton(withTitle: L.tr("나중에", "Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Run brew upgrade — postflight handles kill + relaunch
            let script = "tell application \"Terminal\" to do script \"brew update && brew upgrade --cask toki-monitor\""
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(nil)
            }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L.tr(
            "최신 버전 사용 중",
            "You're up to date"
        )
        alert.informativeText = L.tr(
            "Toki Monitor v\(currentVersion)은 최신 버전입니다.",
            "Toki Monitor v\(currentVersion) is the latest version."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Brew Check

    private func fetchLatestBrewVersion() async -> String? {
        do {
            let data = try await CLIProcessRunner.run(
                executable: "/opt/homebrew/bin/brew",
                arguments: ["info", "--cask", "korjwl1/tap/toki-monitor", "--json=v2"]
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let casks = json["casks"] as? [[String: Any]],
                  let first = casks.first,
                  let ver = first["version"] as? String else { return nil }
            return ver
        } catch {
            return nil
        }
    }

    private func isNewerStable(latest: String, current: String) -> Bool {
        let preReleaseSuffixes = ["alpha", "beta", "rc", "dev", "pre"]
        let lower = latest.lowercased()
        if preReleaseSuffixes.contains(where: { lower.contains($0) }) { return false }
        let lParts = latest.split(separator: ".").compactMap { Int($0) }
        let cParts = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, cParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}
