import SwiftUI

struct DisconnectedView: View {
    let onStartDaemon: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("toki 데몬 미연결")
                .font(.headline)

            Text("toki 데몬이 실행되지 않고 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onStartDaemon) {
                Label("toki 시작", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 260)
    }
}
