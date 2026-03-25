import AppKit
import SwiftUI

/// Checks for app + toki CLI updates via Homebrew and GitHub releases.
/// Shows a custom centered window with release notes.
@MainActor
final class UpdateChecker {
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"
    private static let checkIntervalKey = "lastUpdateCheckDate"

    private let currentVersion: String
    private var updateWindow: NSWindow?

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check on launch. Skips if already checked within 24 hours.
    func checkOnLaunch() {
        let defaults = UserDefaults.standard
        if let lastCheck = defaults.object(forKey: Self.checkIntervalKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return
        }
        Task { await checkAndPrompt() }
    }

    /// Force check (e.g. from settings button).
    func checkNow() {
        Task { await checkAndPrompt(force: true) }
    }

    private func checkAndPrompt(force: Bool = false) async {
        UserDefaults.standard.set(Date(), forKey: Self.checkIntervalKey)

        // Check both toki-monitor and toki CLI
        async let monitorResult = checkMonitor()
        async let tokiResult = checkToki()

        let monitor = await monitorResult
        let toki = await tokiResult

        if monitor == nil && toki == nil {
            if force { showUpToDateAlert() }
            return
        }

        // Don't nag about same versions (unless force)
        if !force {
            let lastNotified = UserDefaults.standard.string(forKey: Self.lastNotifiedKey)
            let key = [monitor?.version, toki?.version].compactMap { $0 }.joined(separator: "+")
            if lastNotified == key { return }
            UserDefaults.standard.set(key, forKey: Self.lastNotifiedKey)
        }

        showUpdateWindow(monitor: monitor, toki: toki)
    }

    // MARK: - Version Checks

    private func checkMonitor() async -> UpdateInfo? {
        guard let release = await fetchLatestGitHubRelease(repo: "korjwl1/toki-monitor") else { return nil }
        guard isNewerStable(latest: release.version, current: currentVersion) else { return nil }

        return UpdateInfo(
            name: "Toki Monitor",
            version: release.version,
            releaseNotes: release.notes,
            brewCommand: "brew update && brew upgrade --cask toki-monitor"
        )
    }

    private func checkToki() async -> UpdateInfo? {
        guard let data = try? await CLIProcessRunner.run(
            executable: TokiPath.resolved, arguments: ["--version"]
        ) else { return nil }
        let installed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "toki ", with: "") ?? ""
        guard !installed.isEmpty else { return nil }

        guard let release = await fetchLatestGitHubRelease(repo: "korjwl1/toki") else { return nil }
        guard isNewerStable(latest: release.version, current: installed) else { return nil }

        return UpdateInfo(
            name: "toki CLI",
            version: release.version,
            releaseNotes: release.notes,
            brewCommand: "brew update && brew upgrade toki"
        )
    }

    // MARK: - Update Window

    private func showUpdateWindow(monitor: UpdateInfo?, toki: UpdateInfo?) {
        let view = UpdateDialogView(
            monitor: monitor,
            toki: toki,
            onUpdate: { [weak self] commands in
                self?.runBrewCommands(commands)
                self?.dismissWindow()
            },
            onLater: { [weak self] in
                self?.dismissWindow()
            }
        )

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = L.tr("업데이트 가능", "Updates Available")
        window.setFrameAutosaveName("")
        window.isReleasedWhenClosed = false
        window.level = .floating

        // Center on screen before showing (use contentRect to get final size)
        let contentSize = hostingController.view.fittingSize
        let finalWidth = max(contentSize.width, 480)
        let finalHeight = min(max(contentSize.height, 200), 400)
        if let screen = NSScreen.main {
            let sf = screen.frame
            let x = sf.origin.x + (sf.width - finalWidth) / 2
            let y = sf.origin.y + (sf.height - finalHeight) / 2
            window.setFrame(NSRect(x: x, y: y, width: finalWidth, height: finalHeight), display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateWindow = window
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L.tr("최신 버전 사용 중", "You're up to date")
        alert.informativeText = L.tr(
            "Toki Monitor v\(currentVersion)은 최신 버전입니다.",
            "Toki Monitor v\(currentVersion) is the latest version."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func dismissWindow() {
        updateWindow?.close()
        updateWindow = nil
    }

    private func runBrewCommands(_ commands: [String]) {
        let combined = commands.joined(separator: " && ")
        // Write a temp script and open it in Terminal
        let scriptPath = NSTemporaryDirectory() + "toki-update.command"
        let scriptContent = """
            #!/bin/bash
            \(combined)
            # Relaunch TokiMonitor after upgrade
            killall TokiMonitor 2>/dev/null
            sleep 1
            open -a TokiMonitor
            osascript -e 'tell application "Terminal" to close front window' &
            exit 0
            """
        try? scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        // Make executable
        chmod(scriptPath, 0o755)
        // Open .command file — macOS opens it in Terminal automatically
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }

    // MARK: - GitHub API

    private struct GitHubRelease {
        let version: String
        let notes: String?
    }

    /// Fetch latest stable release from GitHub API (skips pre-releases).
    private func fetchLatestGitHubRelease(repo: String) async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        // Find first non-prerelease, non-draft release
        for release in releases {
            let prerelease = release["prerelease"] as? Bool ?? false
            let draft = release["draft"] as? Bool ?? false
            if prerelease || draft { continue }

            guard let tagName = release["tag_name"] as? String else { continue }
            // Strip "v" prefix: "v0.1.2" → "0.1.2"
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let notes = release["body"] as? String
            return GitHubRelease(version: version, notes: notes)
        }

        return nil
    }

    private func isNewerStable(latest: String, current: String) -> Bool {
        let preReleaseSuffixes = ["alpha", "beta", "rc", "dev", "pre"]
        let lower = latest.lowercased()
        if preReleaseSuffixes.contains(where: { lower.contains($0) }) { return false }
        // Strip revision suffix (e.g. "0.1.2_1" → "0.1.2")
        let cleanLatest = latest.split(separator: "_").first.map(String.init) ?? latest
        let cleanCurrent = current.split(separator: "_").first.map(String.init) ?? current
        let lParts = cleanLatest.split(separator: ".").compactMap { Int($0) }
        let cParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(lParts.count, cParts.count) {
            let l = i < lParts.count ? lParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}

// MARK: - Update Dialog View

private struct UpdateDialogView: View {
    let monitor: UpdateChecker.UpdateInfo?
    let toki: UpdateChecker.UpdateInfo?
    let onUpdate: ([String]) -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.tr("업데이트 가능", "Updates Available"))
                        .font(.system(size: 16, weight: .bold))
                    Text(updateSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Release notes (scrollable)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let m = monitor {
                        releaseSection(name: m.name, version: m.version, notes: m.releaseNotes)
                    }
                    if let t = toki {
                        releaseSection(name: t.name, version: t.version, notes: t.releaseNotes)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 250)

            Divider()

            // Buttons
            HStack {
                Button(L.tr("나중에", "Later")) { onLater() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.tr("업데이트", "Update")) {
                    var commands: [String] = []
                    if let m = monitor { commands.append(m.brewCommand) }
                    if let t = toki { commands.append(t.brewCommand) }
                    onUpdate(commands)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var updateSummary: String {
        let parts = [monitor, toki].compactMap { $0 }.map { "\($0.name) \($0.version)" }
        return parts.joined(separator: ", ")
    }

    private func releaseSection(name: String, version: String, notes: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) v\(version)")
                .font(.system(size: 13, weight: .semibold))
            if let notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.7))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L.tr("릴리스 노트 없음", "No release notes available"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// Make UpdateInfo accessible to the view
extension UpdateChecker {
    struct UpdateInfo {
        let name: String
        let version: String
        let releaseNotes: String?
        let brewCommand: String
    }
}
