import SwiftUI
import JetKVMTransport

struct ConnectView: View {
    @Environment(Session.self) private var session

    @State private var host: String = ""
    @State private var port: String = "80"
    @State private var password: String = ""
    @State private var useTLS: Bool = false

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
        await session.connect(endpoint: endpoint, password: pwd)
    }
}
