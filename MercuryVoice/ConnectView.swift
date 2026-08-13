import HermesKit
import SwiftUI

/// Connect screen: server URL (accepts host, host:port, full URL, or a
/// pasted dashboard URL with ?token=) + token field. When the server turns
/// out to be gated with a username/password provider, the form switches to
/// a sign-in prompt.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var serverInput = ""
    @State private var tokenInput = ""
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var connecting = false
    @State private var showHelp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("Mercury Voice")
                        .font(.largeTitle.bold())
                    Text("Voice conversations with your Hermes agent")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                if let pending = model.pendingPasswordLogin {
                    passwordLoginForm(pending)
                } else {
                    serverForm
                }

                if model.pendingPasswordLogin == nil, !model.savedServers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent servers").font(.headline)
                        ForEach(model.savedServers) { server in
                            HStack {
                                Button {
                                    connecting = true
                                    Task {
                                        if let parsed = try? ServerEndpoint.parse(
                                            server.urlString)
                                        {
                                            await model.connect(
                                                endpoint: parsed.endpoint,
                                                credentials: model.savedCredentials(
                                                    for: parsed.endpoint))
                                        }
                                        connecting = false
                                    }
                                } label: {
                                    Label(server.urlString, systemImage: "server.rack")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    model.forgetServer(server)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(maxWidth: 420)
                }

                Button("How do I connect?") { showHelp = true }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 24)
            }
            .padding()
        }
        .sheet(isPresented: $showHelp) { ConnectHelpView() }
        .onChange(of: model.pendingPasswordLogin) { _, pending in
            if let pending, usernameInput.isEmpty {
                usernameInput = pending.prefillUsername
            }
            passwordInput = ""
        }
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server").font(.headline)
            TextField(
                "127.0.0.1:8080 or paste the dashboard URL",
                text: $serverInput
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
            .onChange(of: serverInput) { _, newValue in
                // Lift an embedded ?token= into the token field.
                if let parsed = try? ServerEndpoint.parse(newValue),
                    let token = parsed.embeddedToken
                {
                    tokenInput = token
                }
            }

            Text("Session token").font(.headline)
            SecureField("auto-filled from a pasted dashboard URL", text: $tokenInput)
                .textFieldStyle(.roundedBorder)
            Text("Gated servers with a username & password skip this — just Connect.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = model.connectError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button {
                connecting = true
                Task {
                    await model.connect(input: serverInput, token: tokenInput)
                    connecting = false
                }
            } label: {
                if connecting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Connect").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverInput.isEmpty || connecting)
        }
        .frame(maxWidth: 420)
    }

    private func passwordLoginForm(_ pending: AppModel.PendingPasswordLogin) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Sign in to \(pending.endpoint.displayName)",
                systemImage: "lock.shield")
            .font(.headline)
            Text("This server uses \(pending.providerDisplayName) authentication.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Username").font(.headline)
            TextField("Username", text: $usernameInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                #endif

            Text("Password").font(.headline)
            SecureField("Password", text: $passwordInput)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                    .textContentType(.password)
                #endif
                .onSubmit { submitLogin() }

            if let error = model.connectError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button {
                submitLogin()
            } label: {
                if connecting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Sign In").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(usernameInput.isEmpty || passwordInput.isEmpty || connecting)

            Button("Back") { model.cancelPasswordLogin() }
                .buttonStyle(.borderless)
        }
        .frame(maxWidth: 420)
    }

    private func submitLogin() {
        guard !usernameInput.isEmpty, !passwordInput.isEmpty, !connecting else { return }
        connecting = true
        Task {
            await model.signIn(username: usernameInput, password: passwordInput)
            passwordInput = ""
            connecting = false
        }
    }
}

struct ConnectHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    helpSection(
                        "Same Mac",
                        "Run `hermes serve` on this Mac, then paste the dashboard URL it prints (it contains ?token=...). The token changes on every backend restart.")
                    helpSection(
                        "iPhone → Mac over Tailscale",
                        "Run `tailscale serve` on the Mac to proxy the Hermes port — it forwards from loopback on the host, so token mode keeps working. Then connect to the Mac's tailnet name.")
                    helpSection(
                        "iPhone → Mac on LAN",
                        "A backend bound to 127.0.0.1 refuses non-local peers. Either use an SSH tunnel from another machine, or run the backend with a non-loopback bind — that enables gated mode, and this app can sign in with a username & password when the server has one configured.")
                    helpSection(
                        "Username & password (gated servers)",
                        "On a gated (non-loopback) backend, set dashboard.basic_auth.username and password (or password_hash) in the server's config.yaml. Connect without a token and the app will prompt you to sign in.")
                    helpSection(
                        "Where's my token?",
                        "hermes prints and opens http://127.0.0.1:<port>/?token=... at startup. Paste that whole URL into the server field and the token is picked out automatically.")
                }
                .padding()
            }
            .navigationTitle("Connecting")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func helpSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
