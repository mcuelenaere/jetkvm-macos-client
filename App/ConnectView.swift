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

    private var failureMessage: String? {
        if case .failed(let msg) = session.state { return msg } else { return nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect to JetKVM")
                .font(.title)

            Form {
                TextField("Host", text: $host, prompt: Text("kvm.local or 192.168.1.42"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isAwaitingPassword)

                HStack {
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                        .disabled(isAwaitingPassword)
                    Toggle("HTTPS", isOn: $useTLS)
                        .disabled(isAwaitingPassword)
                }

                if isAwaitingPassword || !password.isEmpty {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if isAwaitingPassword {
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
                .disabled(host.isEmpty)
            }
        }
        .padding(40)
        .frame(minWidth: 420)
    }

    @MainActor
    private func connect() async {
        guard let portValue = Int(port), portValue > 0, portValue < 65_536 else { return }
        let endpoint = DeviceEndpoint(host: host, port: portValue, useTLS: useTLS)
        let pwd = password.isEmpty ? nil : password
        await session.connect(endpoint: endpoint, password: pwd)
    }
}
