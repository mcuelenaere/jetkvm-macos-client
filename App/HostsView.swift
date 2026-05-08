import SwiftUI

/// Root window: list of saved hosts. Plus button to add. Double-click
/// or Return to open a connection in a new window.
///
/// The list is keyed by the SavedHost.id so SwiftUI can keep selection
/// stable across edits. Empty state shows a centered hint instead of
/// an empty list — first-launch users need to be told what to do.
struct HostsView: View {
    @Environment(HostStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var selection: SavedHost.ID?
    @State private var showingAdd = false
    @State private var editing: SavedHost?

    var body: some View {
        VStack(spacing: 0) {
            if store.hosts.isEmpty {
                emptyState
            } else {
                List(store.hosts, selection: $selection) { host in
                    HostRow(
                        host: host,
                        isSelected: selection == host.id,
                        onConnect: { connect(host) },
                        onEdit: { editing = host },
                        onDelete: { store.delete(id: host.id) }
                    )
                    .tag(host.id)
                    .contextMenu {
                        Button("Edit…") { editing = host }
                        Button("Delete", role: .destructive) {
                            store.delete(id: host.id)
                        }
                    }
                }
                .listStyle(.inset)
                // Enter on the selected row connects. Double-clicking
                // a row would be the natural macOS gesture, but
                // SwiftUI's List on macOS doesn't expose a per-row
                // double-click hook that doesn't break NSTableView's
                // native single-click selection — the per-row "play"
                // button is the explicit alternative for mouse users.
                .onKeyPress(.return) {
                    guard let id = selection, let host = store.find(id: id) else {
                        return .ignored
                    }
                    connect(host)
                    return .handled
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("JetKVM")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .help("Add a new host.")
            }
        }
        .sheet(isPresented: $showingAdd) {
            HostFormSheet(mode: .add) { host in
                store.add(host)
                selection = host.id
            }
        }
        .sheet(item: $editing) { host in
            HostFormSheet(
                mode: .edit(host),
                onSave: { store.update($0) },
                onDelete: {
                    store.delete(id: host.id)
                    if selection == host.id { selection = nil }
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No saved hosts")
                .font(.title3)
            Text("Click + in the toolbar to add a JetKVM device.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect(_ host: SavedHost) {
        // openWindow with a value spawns a new window — or focuses an
        // existing one for the same id. Either way the user ends up at
        // a session for this host.
        openWindow(value: KVMSessionWindowID(host.id))
    }
}

private struct HostRow: View {
    let host: SavedHost
    let isSelected: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.body)
                Text(verbatim: host.urlString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Edit + Delete reveal next to the play button only on
            // the selected row. SwiftUI's `.animation(_:value:)` works
            // natively for in-body views (unlike toolbar items), so the
            // fade-in is smooth without any state-mirroring tricks.
            if isSelected {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Edit \(host.displayName)")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Delete \(host.displayName)")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            Button(action: onConnect) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    // White on selection blue, .tint on regular rows —
                    // matches the Finder / Mail "icons invert with the
                    // selection background" convention.
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Connect to \(host.displayName)")
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}
