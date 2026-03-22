import SwiftUI

struct AboutPane: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    private let repoURL = "https://github.com/korjwl1/toki_dashboard"
    private let tokiRepoURL = "https://github.com/korjwl1/toki"

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

            // Version
            Text("v\(version) (\(build))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Links
            VStack(spacing: 8) {
                Link(destination: URL(string: repoURL)!) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                        Text("Toki Monitor — GitHub")
                    }
                    .font(.system(size: 12))
                }

                Link(destination: URL(string: tokiRepoURL)!) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text("toki CLI — GitHub")
                    }
                    .font(.system(size: 12))
                }

                Link(destination: URL(string: repoURL + "/issues")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug")
                        Text(L.tr("버그 리포트", "Report a Bug"))
                    }
                    .font(.system(size: 12))
                }
            }

            // License
            Text("MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
