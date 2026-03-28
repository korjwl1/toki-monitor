import AppKit
import SwiftUI

/// Minimum toki CLI major version required for compatibility with this version of toki-monitor.
/// Must be bumped whenever toki introduces breaking protocol changes.
let requiredTokiMajorVersion = 2

/// Checks toki CLI major version and shows a non-dismissible modal if outdated.
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
    /// shows a non-dismissible update-required modal and disables query features.
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

    private func showUpdateRequiredModal(installedMajor: Int) {
        let view = TokiUpdateRequiredView(
            installedVersion: "v\(installedMajor).x",
            requiredVersion: "v\(requiredTokiMajorVersion)"
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = L.tr("toki 업데이트 필요", "toki Update Required")
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        // Non-dismissible: no close button, ESC does nothing
        window.standardWindowButton(.closeButton)?.isEnabled = false
        window.standardWindowButton(.closeButton)?.isHidden = true

        if let screen = NSScreen.main {
            let sf = screen.frame
            let size = hostingController.view.fittingSize
            let w = max(size.width, 440)
            let h = max(size.height, 240)
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

            Button(L.tr("brew upgrade toki 복사", "Copy brew upgrade toki")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew update && brew upgrade toki", forType: .string)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 440)
    }
}
