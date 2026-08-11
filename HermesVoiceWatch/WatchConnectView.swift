import HermesKit
import SwiftUI

/// Watch connect screen. Typing server URLs and tokens on a watch is
/// miserable, so the primary path is credential sync from the iPhone
/// (CredentialSync adopts servers as they arrive and auto-connects);
/// this screen lists already-synced servers for manual re-connects and
/// explains the setup path when nothing has synced yet.
struct WatchConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            List {
                if model.pendingPasswordLogin != nil {
                    Section {
                        Label("Sign-in required", systemImage: "lock.shield")
                            .font(.headline)
                        Text("This server needs a username and password. Sign in once in the iPhone app and the watch will pick it up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Back") { model.cancelPasswordLogin() }
                    }
                } else if model.savedServers.isEmpty {
                    Section {
                        Label("Set up on iPhone", systemImage: "iphone")
                            .font(.headline)
                        Text("Connect to your Hermes server once in the iPhone app — the server and sign-in sync here automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Servers") {
                        ForEach(model.savedServers) { server in
                            Button {
                                connect(to: server)
                            } label: {
                                Label(server.urlString, systemImage: "server.rack")
                                    .lineLimit(2)
                            }
                            .disabled(connecting)
                        }
                    }
                }

                if connecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                if let error = model.connectError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Hermes")
        }
    }

    private func connect(to server: AppModel.SavedServer) {
        guard let parsed = try? ServerEndpoint.parse(server.urlString) else { return }
        connecting = true
        Task {
            await model.connect(
                endpoint: parsed.endpoint,
                credentials: model.savedCredentials(for: parsed.endpoint))
            connecting = false
        }
    }
}
