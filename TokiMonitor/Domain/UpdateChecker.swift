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
        guard let latest = await fetchLatestBrewVersion(
            formula: "korjwl1/tap/toki-monitor", cask: true
        ) else { return nil }
        guard isNewerStable(latest: latest, current: currentVersion) else { return nil }

        let notes = await fetchReleaseNotes(repo: "korjwl1/toki-monitor", tag: "v\(latest)")
        return UpdateInfo(
            name: "Toki Monitor",
            version: latest,
            releaseNotes: notes,
            brewCommand: "brew update && brew upgrade --cask toki-monitor"
        )
    }

    private func checkToki() async -> UpdateInfo? {
        // Get installed toki version
        guard let data = try? await CLIProcessRunner.run(
            executable: TokiPath.resolved, arguments: ["--version"]
        ) else { return nil }
        let installed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "toki ", with: "") ?? ""
        guard !installed.isEmpty else { return nil }

        guard let latest = await fetchLatestBrewVersion(
            formula: "korjwl1/tap/toki", cask: false
        ) else { return nil }
        guard isNewerStable(latest: latest, current: installed) else { return nil }

        let notes = await fetchReleaseNotes(repo: "korjwl1/toki", tag: "v\(latest)")
        return UpdateInfo(
            name: "toki CLI",
            version: latest,
            releaseNotes: notes,
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
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

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
        let script = "tell application \"Terminal\" to do script \"\(combined)\""
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(nil)
        }
    }

    // MARK: - GitHub Release Notes

    private func fetchReleaseNotes(repo: String, tag: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["body"] as? String else {
            return nil
        }
        return body
    }

    // MARK: - Brew Check

    private static let brewPath: String = {
        // Apple Silicon: /opt/homebrew/bin/brew, Intel: /usr/local/bin/brew
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/brew"
    }()

    private func fetchLatestBrewVersion(formula: String, cask: Bool) async -> String? {
        let args = cask
            ? ["info", "--cask", formula, "--json=v2"]
            : ["info", "--formula", formula, "--json=v2"]
        do {
            let data = try await CLIProcessRunner.run(
                executable: Self.brewPath, arguments: args
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if cask {
                if let casks = json["casks"] as? [[String: Any]],
                   let first = casks.first,
                   let ver = first["version"] as? String { return ver }
            } else {
                if let formulae = json["formulae"] as? [[String: Any]],
                   let first = formulae.first,
                   let versions = first["versions"] as? [String: Any],
                   let stable = versions["stable"] as? String { return stable }
            }
            return nil
        } catch {
            return nil
        }
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
            .frame(maxHeight: 250)

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
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
