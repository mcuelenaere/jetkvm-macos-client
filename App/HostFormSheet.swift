import SwiftUI

/// Add/edit dialog for a SavedHost. Same form for both — the
/// `mode` switches between Save (new entry) and Update + Delete
/// (existing). The modal returns through a callback closure rather
/// than via Bindings so the host's edits stay isolated until the
/// user explicitly confirms.
struct HostFormSheet: View {
    enum Mode {
        case add
        case edit(SavedHost)
    }

    let mode: Mode
    let onSave: (SavedHost) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var useTLS: Bool

    init(
        mode: Mode,
        onSave: @escaping (SavedHost) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _port = State(initialValue: "80")
            _useTLS = State(initialValue: false)
        case .edit(let existing):
            _name = State(initialValue: existing.name)
            _host = State(initialValue: existing.host)
            _port = State(initialValue: String(existing.port))
            _useTLS = State(initialValue: existing.useTLS)
        }
    }

    private var title: String {
        switch mode {
        case .add: return "Add Host"
        case .edit: return "Edit Host"
        }
    }

    private var saveLabel: String {
        switch mode {
        case .add: return "Add"
        case .edit: return "Save"
        }
    }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        Int(port).map { $0 > 0 && $0 < 65_536 } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2)

            Form {
                TextField("Name (optional)", text: $name, prompt: Text("My desktop"))
                    .textFieldStyle(.roundedBorder)
                TextField("Host", text: $host, prompt: Text("kvm.local or 192.168.1.42"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                    Toggle("HTTPS", isOn: $useTLS)
                        .help("Only works against a JetKVM behind a reverse proxy with a real CA-issued certificate.")
                }
            }

            HStack {
                if let onDelete {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(saveLabel) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(minWidth: 420)
    }

    private func save() {
        guard let portValue = Int(port) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let saved: SavedHost
        switch mode {
        case .add:
            saved = SavedHost(
                name: trimmedName,
                host: trimmedHost,
                port: portValue,
                useTLS: useTLS
            )
        case .edit(let existing):
            saved = SavedHost(
                id: existing.id,
                name: trimmedName,
                host: trimmedHost,
                port: portValue,
                useTLS: useTLS
            )
        }
        onSave(saved)
        dismiss()
    }
}
