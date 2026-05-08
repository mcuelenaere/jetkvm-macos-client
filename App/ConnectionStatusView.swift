import SwiftUI
import JetKVMTransport

/// Inline connection-flow UI shown inside a KVMSessionWindow before
/// the peer connection is up. Renders a centered card over a black
/// backdrop with phase / error / password fields based on
/// session.state. Crossfades out once .connected (the parent switches
/// to KVMWindowView).
struct ConnectionStatusView: View {
    @Environment(Session.self) private var session
    let host: SavedHost
    /// Called when the user clicks Cancel. Parent closes the window.
    let onCancel: () -> Void
    /// Called when the user retries after a failure. Parent re-runs
    /// the connect flow with a fresh attempt.
    let onRetry: () -> Void

    @State private var password: String = ""
    @State private var rememberPassword: Bool = true

    private var connectingPhase: Session.State.Phase? {
        if case .connecting(let phase) = session.state { return phase } else { return nil }
    }

    private var isAwaitingPassword: Bool {
        if case .awaitingPassword = session.state { return true } else { return false }
    }

    private var failureMessage: String? {
        if case .failed(let msg) = session.state { return msg } else { return nil }
    }

    /// True between ICE-connected and the first remote video track
    /// arriving. KVMSessionWindow keeps the overlay visible across
    /// this gap so we own the "video is on its way" affordance here.
    private var isAwaitingVideo: Bool {
        if case .connected = session.state, session.videoTrack == nil { return true }
        return false
    }

    private var showSpinner: Bool {
        connectingPhase != nil || isAwaitingVideo
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            card
                .padding(28)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 460)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if showSpinner {
                    ProgressView().controlSize(.small)
                }
                Text(host.displayName)
                    .font(.headline)
                Spacer()
            }

            Text(verbatim: host.urlString)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let phase = connectingPhase {
                Text(phase.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isAwaitingVideo {
                Text("Receiving video stream…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isAwaitingPassword {
                passwordSection
            } else if let failureMessage {
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                if failureMessage != nil {
                    Button("Retry") { onRetry() }
                        .keyboardShortcut(.defaultAction)
                }
                if isAwaitingPassword {
                    Button("Sign In") {
                        Task { await submitPassword() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
                }
            }
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Device requires a password.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await submitPassword() } }
            Toggle("Remember password", isOn: $rememberPassword)
                .help("Save the password to the macOS Keychain so it auto-fills next time you connect to this host.")
        }
    }

    @MainActor
    private func submitPassword() async {
        guard !password.isEmpty else { return }
        if rememberPassword {
            PasswordVault.save(password, for: host.host)
        } else {
            PasswordVault.delete(for: host.host)
        }
        await session.connect(endpoint: host.endpoint, password: password)
    }
}
