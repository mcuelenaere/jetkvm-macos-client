import SwiftUI
import JetKVMTransport

struct ConnectView: View {
    @Environment(Session.self) private var session

    @State private var host: String = ""
    @State private var port: String = "80"
    @State private var password: String = ""
    @State private var useTLS: Bool = false
    @State private var rememberPassword: Bool = true

    private var isAwaitingPassword: Bool {
        if case .awaitingPassword = session.state { return true } else { return false }
    }

    private var connectingPhase: Session.State.Phase? {
        if case .connecting(let phase) = session.state { return phase } else { return nil }
    }

    private var failureMessage: String? {
        if case .failed(let msg) = session.state { return msg } else { return nil }
    }

    private var inputsLocked: Bool {
        connectingPhase != nil || isAwaitingPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect to JetKVM")
                .font(.title)

            Form {
                TextField("Host", text: $host, prompt: Text("kvm.local or 192.168.1.42"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(inputsLocked)
                    .onChange(of: host) { _, new in
                        autofillPasswordIfAvailable(for: new)
                    }
                    .onSubmit {
                        // Also handles paste-then-Tab — try filling
                        // immediately if the user committed the host.
                        autofillPasswordIfAvailable(for: host)
                    }

                HStack {
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .disabled(inputsLocked)
                    Toggle("HTTPS", isOn: $useTLS)
                        .disabled(inputsLocked)
                        .help("Only works against a JetKVM behind a reverse proxy with a real CA-issued certificate. The default self-signed certificate is not currently supported on macOS — use HTTP for the LAN case.")
                }

                if isAwaitingPassword || !password.isEmpty {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Remember password", isOn: $rememberPassword)
                        .help("Save the password to the macOS Keychain so it auto-fills the next time you connect to this host.")
                }
            }

            if let phase = connectingPhase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isAwaitingPassword {
                Text("Device requires a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button(isAwaitingPassword ? "Sign In" : "Connect") {
                    Task { await connect() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || connectingPhase != nil)
            }
        }
        .padding(40)
        .frame(minWidth: 420)
    }

    @MainActor
    private func connect() async {
        guard let portValue = Int(port), portValue > 0, portValue < 65_536 else { return }
        let endpoint = DeviceEndpoint(
            host: host,
            port: portValue,
            useTLS: useTLS
        )
        let pwd = password.isEmpty ? nil : password
        // Persist before kicking off connect so the next launch finds
        // the password regardless of how this attempt resolves. If it
        // ends up being wrong, the user types a new one next time and
        // we overwrite. On explicit toggle-off, remove the entry.
        if let pwd {
            if rememberPassword {
                PasswordVault.save(pwd, for: host)
            } else {
                PasswordVault.delete(for: host)
            }
        }
        await session.connect(endpoint: endpoint, password: pwd)
    }

    /// Auto-fill the password field when the user types a host we
    /// already have a saved entry for. Only overwrite when the field
    /// is empty so we don't trample what the user is typing.
    private func autofillPasswordIfAvailable(for host: String) {
        guard !host.isEmpty, password.isEmpty else { return }
        if let saved = PasswordVault.load(for: host) {
            password = saved
        }
    }
}
