import SwiftUI

struct SyncSettingsView: View {
    @State private var syncManager = SyncManager.shared
    @State private var showLoginSheet = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                stateRow
                    .background(Color.clear.preference(key: ScrollTopYKey.self, value: 0))
                    .scrollTopTracker
            }

            if syncManager.isConfigured {
                Section(L.sync.status) {
                    if case .configured(let addr, let url) = syncManager.state {
                        LabeledContent(L.sync.serverAddress, value: addr)
                        LabeledContent("HTTP URL", value: url)
                    }
                    Button(role: .destructive) {
                        syncManager.disable()
                    } label: {
                        Label(L.sync.disableSync, systemImage: "xmark.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L.sync.title)
        .sheet(isPresented: $showLoginSheet) {
            SyncLoginSheet { result in
                showLoginSheet = false
                switch result {
                case .success:
                    syncManager.reload()
                    errorMessage = nil
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
        }
        .if(errorMessage != nil) { view in
            view.overlay(alignment: .bottom) {
                Text(errorMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch syncManager.state {
        case .notConfigured:
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text(L.sync.notConfigured)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.sync.enableSync) { showLoginSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .configured(let addr, _):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L.tr("연결됨", "Connected"))
                Spacer()
                Text(addr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tokenExpired:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L.sync.tokenExpired)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.sync.login) { showLoginSheet = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Login Sheet

private struct SyncLoginSheet: View {
    var onComplete: (Result<SyncCredentials, Error>) -> Void

    @State private var httpURL = "https://"
    @State private var serverAddr = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.sync.enableSync)
                    .font(.headline)
                Spacer()
                Button(L.tr("취소", "Cancel")) { dismiss() }
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField(L.sync.serverURL, text: $httpURL)
                        .textContentType(.URL)
                    TextField(L.sync.syncAddr, text: $serverAddr)
                        .textContentType(.URL)
                        .help(L.tr("TCP 동기화 주소 (예: sync.example.com:9090)", "TCP sync address (e.g. sync.example.com:9090)"))
                }
                Section {
                    TextField(L.sync.username, text: $username)
                        .textContentType(.username)
                    SecureField(L.sync.password, text: $password)
                        .textContentType(.password)
                }
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            HStack {
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L.sync.login) { performLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(httpURL.isEmpty || username.isEmpty || password.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 420)
    }

    private func performLogin() {
        isLoading = true
        errorMessage = nil
        let httpBase = httpURL.hasSuffix("/") ? String(httpURL.dropLast()) : httpURL
        let addr = serverAddr.isEmpty ? deriveAddr(from: httpBase) : serverAddr

        Task { @MainActor in
            do {
                let creds = try await SyncClient.shared.login(
                    httpURL: httpBase, serverAddr: addr,
                    username: username, password: password
                )
                isLoading = false
                onComplete(.success(creds))
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deriveAddr(from httpURL: String) -> String {
        guard let host = URLComponents(string: httpURL)?.host else { return httpURL }
        return "\(host):9090"
    }
}

// MARK: - View helper

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
