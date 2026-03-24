import SwiftUI

struct AboutPane: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    private let repoURL = "https://github.com/korjwl1/toki-monitor"
    private let tokiRepoURL = "https://github.com/korjwl1/toki"

    @State private var tokiVersion: String?
    @State private var monitorUpdate: String?
    @State private var tokiUpdate: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }

            // Name + description
            VStack(spacing: 6) {
                Text("Toki Monitor")
                    .font(.system(size: 20, weight: .bold))
                Text(L.tr("macOS 메뉴바용 AI 토큰 사용량 모니터", "AI token usage monitor for macOS menu bar"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Versions
            VStack(spacing: 4) {
                Text("Toki Monitor v\(version) (\(build))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if let tokiVer = tokiVersion {
                    Text("toki CLI v\(tokiVer)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // Update notices
            VStack(spacing: 4) {
                if let monitorVer = monitorUpdate {
                    updateBadge(
                        L.tr("Toki Monitor \(monitorVer) 업데이트 가능", "Toki Monitor \(monitorVer) available"),
                        command: "brew update && brew upgrade --cask toki-monitor"
                    )
                }
                if let tokiVer = tokiUpdate {
                    updateBadge(
                        L.tr("toki CLI \(tokiVer) 업데이트 가능", "toki CLI \(tokiVer) available"),
                        command: "brew update && brew upgrade toki"
                    )
                }
            }

            // Links
            VStack(spacing: 8) {
                if let url = URL(string: repoURL) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Toki Monitor — GitHub")
                    }
                    .font(.system(size: 12))
                }
                }

                if let url = URL(string: tokiRepoURL) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("toki CLI — GitHub")
                    }
                    .font(.system(size: 12))
                }
                }

                if let url = URL(string: repoURL + "/issues") {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug")
                        Text(L.tr("버그 리포트", "Report a Bug"))
                    }
                    .font(.system(size: 12))
                }
                }
            }

            // License
            Text("FSL-1.1-Apache-2.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await checkVersions() }
    }

    // MARK: - Update Badge

    private func updateBadge(_ text: String, command: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L.tr("명령어 복사", "Copy command"))
        }
    }

    // MARK: - Version Check

    private func checkVersions() async {
        // Get installed toki version
        if let data = try? await CLIProcessRunner.run(
            executable: TokiPath.resolved,
            arguments: ["--version"]
        ) {
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // "toki 1.1.4" → "1.1.4"
            tokiVersion = output.replacingOccurrences(of: "toki ", with: "")
        }

        // Check brew for latest versions (ignore pre-release like alpha/beta/rc)
        await checkBrewUpdate(formula: "korjwl1/tap/toki-monitor", cask: true) { latest in
            if isNewerStable(latest: latest, current: version) { monitorUpdate = latest }
        }
        await checkBrewUpdate(formula: "korjwl1/tap/toki", cask: false) { latest in
            if let installed = tokiVersion, isNewerStable(latest: latest, current: installed) { tokiUpdate = latest }
        }
    }

    /// Returns true only if `latest` is a stable release newer than `current`.
    /// Ignores pre-release tags (alpha, beta, rc).
    private func isNewerStable(latest: String, current: String) -> Bool {
        let preReleaseSuffixes = ["alpha", "beta", "rc", "dev", "pre"]
        let lower = latest.lowercased()
        if preReleaseSuffixes.contains(where: { lower.contains($0) }) { return false }
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

    private static let brewPath: String = {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/opt/homebrew/bin/brew"
    }()

    private func checkBrewUpdate(formula: String, cask: Bool, onResult: @MainActor (String) -> Void) async {
        let args = cask
            ? ["info", "--cask", formula, "--json=v2"]
            : ["info", "--formula", formula, "--json=v2"]
        do {
            let data = try await CLIProcessRunner.run(
                executable: Self.brewPath,
                arguments: args
            )
            // Parse version from brew JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if cask {
                    if let casks = json["casks"] as? [[String: Any]],
                       let first = casks.first,
                       let ver = first["version"] as? String {
                        await onResult(ver)
                    }
                } else {
                    if let formulae = json["formulae"] as? [[String: Any]],
                       let first = formulae.first,
                       let versions = first["versions"] as? [String: Any],
                       let stable = versions["stable"] as? String {
                        await onResult(stable)
                    }
                }
            }
        } catch {
            // brew not available or formula not found — skip
        }
    }
}
