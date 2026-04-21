import AppKit
import SwiftUI

/// Minimum toki CLI major version required for compatibility with this version of toki-monitor.
/// Must be bumped whenever toki introduces breaking protocol changes.
let requiredTokiMajorVersion = 2

/// Checks toki CLI major version and shows an update-required modal if outdated.
@MainActor
final class VersionCompatibilityChecker {

    /// Returns the installed toki major version, or nil if toki is not found.
    func installedTokiMajorVersion() async -> Int? {
        guard let data = try? await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["--version"]
        ) else { return nil }

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Expected: "toki 2.0.0"
        let versionString = output.hasPrefix("toki ") ? String(output.dropFirst(5)) : output
        guard let major = versionString.split(separator: ".").first.flatMap({ Int($0) }) else {
            return nil
        }
        return major
    }

    /// Check version on launch. If toki is installed but major version is too old,
    /// shows an update-required modal and disables query features.
    /// If toki is not installed, does nothing (toki-monitor can still work via daemon).
    func checkOnLaunch() {
        Task {
            guard let major = await installedTokiMajorVersion() else { return }
            if major < requiredTokiMajorVersion {
                showUpdateRequiredModal(installedMajor: major)
            }
        }
    }

    // MARK: - Modal

    private var updateWindow: NSWindow?

    /// Open Terminal with brew upgrade toki.
    private func runUpdate() {
        let scriptPath = NSTemporaryDirectory() + "toki-version-update.command"
        let script = """
        #!/bin/bash
        brew update && brew upgrade toki
        osascript -e 'tell application "Terminal" to close (every window whose name contains "toki-version-update")' &
        exit 0
        """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath, 0o755)
        NSWorkspace.shared.open(URL(fileURLWithPath: scriptPath))
    }

    /// Re-check version and close modal if now up to date. Returns true if OK.
    func recheckVersion() async -> Bool {
        guard let major = await installedTokiMajorVersion() else { return false }
        if major >= requiredTokiMajorVersion {
            updateWindow?.close()
            updateWindow = nil
            return true
        }
        return false
    }

    private func showUpdateRequiredModal(installedMajor: Int) {
        let view = TokiUpdateRequiredView(
            installedVersion: "v\(installedMajor).x",
            requiredVersion: "v\(requiredTokiMajorVersion)",
            onUpdate: { [weak self] in self?.runUpdate() },
            onRecheck: { [weak self] in
                guard let self else { return }
                Task { await self.recheckVersion() }
            },
            onDismiss: { [weak self] in
                self?.updateWindow?.close()
                self?.updateWindow = nil
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = L.tr("toki 업데이트 필요", "toki Update Required")
        window.isReleasedWhenClosed = false
        window.level = .modalPanel

        if let screen = NSScreen.main {
            let sf = screen.frame
            let size = hostingController.view.fittingSize
            let w = max(size.width, 440)
            let h = max(size.height, 260)
            let x = sf.origin.x + (sf.width - w) / 2
            let y = sf.origin.y + (sf.height - h) / 2
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateWindow = window
    }
}

// MARK: - View

private struct TokiUpdateRequiredView: View {
    let installedVersion: String
    let requiredVersion: String
    let onUpdate: () -> Void
    let onRecheck: () -> Void
    let onDismiss: () -> Void

    @State private var didClickUpdate = false
    @State private var isRechecking = false
    @State private var recheckFailed = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(L.tr("toki 업데이트가 필요합니다", "toki Update Required"))
                    .font(.system(size: 16, weight: .bold))

                Text(L.tr(
                    "현재 toki \(installedVersion)이 설치되어 있습니다.\ntoki-monitor는 toki \(requiredVersion) 이상을 요구합니다.\n쿼리 기능을 사용하려면 toki를 업데이트하세요.",
                    "toki \(installedVersion) is installed, but toki-monitor requires toki \(requiredVersion) or later.\nPlease update toki to use query features."
                ))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            if recheckFailed {
                Text(L.tr("아직 업데이트가 완료되지 않았습니다.", "Update not yet complete."))
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if !didClickUpdate {
                HStack(spacing: 12) {
                    Button(L.tr("나중에", "Later")) {
                        onDismiss()
                    }
                    Button(L.tr("지금 업데이트", "Update Now")) {
                        onUpdate()
                        didClickUpdate = true
                        recheckFailed = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 12) {
                    Button(L.tr("나중에", "Later")) {
                        onDismiss()
                    }
                    Button(L.tr("업데이트 완료 → 재확인", "Done Updating → Re-check")) {
                        isRechecking = true
                        recheckFailed = false
                        onRecheck()
                        // Give it a moment then reset rechecking state if not closed
                        Task {
                            try? await Task.sleep(for: .seconds(3))
                            isRechecking = false
                            recheckFailed = true
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRechecking)
                    .overlay {
                        if isRechecking {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
