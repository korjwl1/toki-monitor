import SwiftUI

struct DisconnectedView: View {
    let state: ConnectionState
    let onStartDaemon: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("toki 데몬 미연결")
                .font(.headline)

            statusText

            Button(action: onStartDaemon) {
                Label("toki 시작", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isReconnecting)
        }
        .padding(20)
        .frame(width: 260)
    }

    @ViewBuilder
    private var statusText: some View {
        switch state {
        case .disconnected:
            Text("toki 데몬이 실행되지 않고 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .reconnecting(let attempt, let max):
            Text("재연결 중... (\(attempt)/\(max))")
                .font(.caption)
                .foregroundStyle(.orange)
        case .connected:
            EmptyView()
        }
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }
}
