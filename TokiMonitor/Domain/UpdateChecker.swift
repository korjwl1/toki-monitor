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
        cleanupTempScripts()
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
        // Gate the prompt on the tap: `brew upgrade` installs from the tap cask,
        // so a GitHub release that the tap hasn't been bumped to yet can't be
        // delivered. Don't nag daily for something brew can't install.
        guard await tapCanDeliver(version: release.version, tapFilePath: "Casks/toki-monitor.rb", label: "monitor cask") else {
            return nil
        }

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
        guard await tapCanDeliver(version: release.version, tapFilePath: "Formula/toki.rb", label: "toki formula") else {
            return nil
        }

        return UpdateInfo(
            name: "toki CLI",
            version: release.version,
            releaseNotes: release.notes,
            brewCommand: "brew update && brew upgrade toki"
        )
    }

    /// True when the tap already carries `version` (or newer), i.e. `brew upgrade`
    /// can actually install it. Reads the raw formula/cask file from the tap repo
    /// on GitHub (fast, always current) and parses its `version "x.y.z"`. If the
    /// tap can't be read, err on the side of NOT prompting.
    private func tapCanDeliver(version: String, tapFilePath: String, label: String) async -> Bool {
        guard let tapVersion = await fetchTapFileVersion(path: tapFilePath) else {
            print("[UpdateChecker] tap \(label) version unavailable; deferring update prompt for \(version)")
            return false
        }
        guard SemVer.core(tapVersion) >= SemVer.core(version) else {
            print("[UpdateChecker] release \(version) not yet in tap \(label) (tap has \(tapVersion)); deferring prompt")
            return false
        }
        return true
    }

    /// Fetches `https://raw.githubusercontent.com/korjwl1/homebrew-tap/main/<path>`
    /// and extracts the `version "x.y.z"` field.
    private func fetchTapFileVersion(path: String) async -> String? {
        guard let url = URL(string: "https://raw.githubusercontent.com/korjwl1/homebrew-tap/main/\(path)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Match: version "0.2.4"
        guard let range = text.range(of: #"version\s+"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[range])
        guard let vRange = matched.range(of: #""([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        return String(matched[vRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: - Update Window

    private func showUpdateWindow(monitor: UpdateInfo?, toki: UpdateInfo?) {
        // Never stack a second window over an existing one: overwriting
        // `updateWindow` would orphan the previous window (isReleasedWhenClosed
        // = false), and dismissWindow() could no longer reach it — the root of
        // the "update window won't close" reports. Reuse the open one instead.
        if updateWindow != nil {
            NSApp.activate(ignoringOtherApps: true)
            updateWindow?.makeKeyAndOrderFront(nil)
            return
        }

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

    private static let updateScriptPath = NSTemporaryDirectory() + "toki-update.command"

    private func runBrewCommands(_ commands: [String]) {
        let combined = commands.joined(separator: " && ")
        // The script ONLY runs brew upgrade. The cask postflight is the single
        // owner of the app restart (killall + open) — doing it here too caused a
        // duplicate-restart race (the "duplicate update window" reports). On
        // success we close the Terminal window (the cask relaunches the app mid-
        // flow — expected); on failure we keep it open so the user sees why.
        let scriptContent = """
        #!/bin/bash
        echo "Updating Toki Monitor…"
        echo
        if \(combined); then
          echo
          echo "Update complete. Toki Monitor will relaunch automatically."
          # The cask postflight restarts the app; just close this window.
          osascript -e 'tell application "Terminal" to close (every window whose name contains "toki-update")' &
          exit 0
        else
          status=$?
          echo
          echo "Update failed (exit $status). Review the errors above."
          echo "Press any key to close this window."
          read -n 1 -s
          exit $status
        fi

        """
        try? scriptContent.write(toFile: Self.updateScriptPath, atomically: true, encoding: .utf8)
        // Make executable
        chmod(Self.updateScriptPath, 0o755)
        // Open .command file — macOS opens it in Terminal automatically
        NSWorkspace.shared.open(URL(fileURLWithPath: Self.updateScriptPath))
    }

    /// Remove a leftover update script from a previous run. The cask postflight
    /// kills this app mid-update, so the script can't clean up after itself.
    private func cleanupTempScripts() {
        try? FileManager.default.removeItem(atPath: Self.updateScriptPath)
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("[UpdateChecker] GitHub release check for \(repo) failed: \(error.localizedDescription)")
            return nil
        }

        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard httpResponse.statusCode == 200 else {
            // 403 with a zero rate-limit-remaining header = unauthenticated
            // 60/hr limit exhausted. Surface it so missed checks are diagnosable.
            if httpResponse.statusCode == 403,
               httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                print("[UpdateChecker] GitHub API rate limit reached (60/hr) checking \(repo); update check skipped")
            } else {
                print("[UpdateChecker] GitHub release check for \(repo) returned HTTP \(httpResponse.statusCode)")
            }
            return nil
        }
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            print("[UpdateChecker] GitHub release response for \(repo) was not the expected JSON array")
            return nil
        }

        // Pick the HIGHEST stable version. GitHub returns releases sorted by
        // publish date, not version, so a backported older point-release
        // published after a newer one would otherwise be treated as "latest".
        var best: GitHubRelease?
        for release in releases {
            let prerelease = release["prerelease"] as? Bool ?? false
            let draft = release["draft"] as? Bool ?? false
            if prerelease || draft { continue }

            guard let tagName = release["tag_name"] as? String else { continue }
            // Strip "v" prefix: "v0.1.2" → "0.1.2"
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            if SemVer.isPrerelease(version) { continue }
            let candidate = GitHubRelease(version: version, notes: release["body"] as? String)
            if let current = best {
                if SemVer.core(version) > SemVer.core(current.version) { best = candidate }
            } else {
                best = candidate
            }
        }

        return best
    }

    private func isNewerStable(latest: String, current: String) -> Bool {
        SemVer.isNewerStable(latest: latest, current: current)
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
                    // toki를 먼저 업그레이드해야 toki-monitor 재시작 시 버전 불일치가 없음
                    if let t = toki { commands.append(t.brewCommand) }
                    if let m = monitor { commands.append(m.brewCommand) }
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
