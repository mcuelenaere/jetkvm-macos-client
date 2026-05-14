import SwiftUI
import JetKVMTransport

/// Identifier for a KVM session window. Carries the full set of
/// fields needed to connect (display name + endpoint) so the same
/// shape works for both saved and discovered (mDNS) hosts — the
/// session window doesn't need to look anything up.
///
/// Codable conformance refuses to decode: SwiftUI's macOS-14
/// WindowGroup auto-restores prior windows from Codable values, and
/// we'd rather always launch into HostsView. Encoding still works in
/// case SwiftUI persists state during a runtime session.
/// (`restorationBehavior(.disabled)` would express this more
/// directly but it's macOS 15+.)
struct KVMSessionWindowID: Hashable, Codable {
    let displayName: String
    let host: String
    let port: Int
    let useTLS: Bool

    init(saved: SavedHost) {
        self.displayName = saved.displayName
        self.host = saved.host
        self.port = saved.port
        self.useTLS = saved.useTLS
    }

    init(discovered: DiscoveredHost) {
        self.displayName = discovered.instanceName
        self.host = discovered.host
        self.port = discovered.port
        self.useTLS = discovered.useTLS
    }

    init(from decoder: Decoder) throws {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "KVM session windows are intentionally not restored"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([displayName, host, "\(port)", "\(useTLS)"])
    }
}

/// Bridges SwiftUI's App lifecycle to a small NSApplicationDelegate.
/// Used to opt into "quit when the last window closes" and to add
/// a "Show Hosts" item to the dock-icon right-click menu so the
/// user can re-summon the hosts window after closing it (while a
/// session window keeps the app alive).
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Items to add to the dock icon's right-click menu. The
    /// system-provided entries (Quit, Show, Options, etc.) appear
    /// below ours automatically.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let showHosts = NSMenuItem(
            title: String(localized: "Show Hosts"),
            action: #selector(showHosts(_:)),
            keyEquivalent: ""
        )
        showHosts.target = self
        menu.addItem(showHosts)
        return menu
    }

    /// `openWindow(id:)` lives on the SwiftUI environment and
    /// can't be reached from a plain NSObject, so we post a
    /// notification HostsView / KVMSessionWindow pick up. The
    /// hosts scene is a `Window` (single-instance), so the
    /// resulting `openWindow(id: "hosts")` either brings the
    /// existing window forward or opens a fresh one.
    @objc private func showHosts(_ sender: Any?) {
        NotificationCenter.default.post(name: .regiShowHosts, object: nil)
    }
}

/// Closures the active KVM session window publishes so the app-wide
/// File menu can switch from "Add Host…" (hosts window focused) to
/// session-specific commands (KVM window focused). Closures capture
/// each window's local SwiftUI state — the menu just invokes them.
struct SessionActions {
    let toggleControls: () -> Void
    let toggleStats: () -> Void
}

private struct SessionActionsFocusedValueKey: FocusedValueKey {
    typealias Value = SessionActions
}

extension FocusedValues {
    /// Set by the focused KVM session window; nil when any other
    /// window (the hosts list, or no window) is active.
    var sessionActions: SessionActions? {
        get { self[SessionActionsFocusedValueKey.self] }
        set { self[SessionActionsFocusedValueKey.self] = newValue }
    }
}

/// File-menu command set. Replaces the entire SwiftUI-auto-generated
/// `.newItem` group (which would otherwise add "New Regi Window" and
/// "New KVM Session Window" entries — both wrong: hosts is single-
/// instance, session windows are opened by selecting a host).
///
/// Menu contents switch based on which window is frontmost:
///   - hosts window focused   → "Add Host…"
///   - KVM session focused    → "Show Controls" / "Show Connection
///                              Stats" (no "Disconnect" — ⌘W close-
///                              window already tears the session
///                              down via KVMSessionWindow.onDisappear)
struct RegiCommands: Commands {
    @FocusedValue(\.sessionActions) private var sessionActions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if let sessionActions {
                Button("Show Controls", action: sessionActions.toggleControls)
                    .keyboardShortcut("k", modifiers: .command)
                Button("Show Connection Stats", action: sessionActions.toggleStats)
                    .keyboardShortcut("i", modifiers: .command)
            } else {
                Button("Add Host…") {
                    NotificationCenter.default.post(name: .regiAddHost, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        // No custom `Window > Hosts` command: SwiftUI auto-injects
        // a Window menu entry for every open scene (titled "Regi"
        // for the hosts window via the `Window("Regi", …)` first
        // parameter). Adding our own duplicated it. Together with
        // the dock-icon reopen wired up in AppDelegate, the auto-
        // entry covers the navigation case.
    }
}

@main
struct RegiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hostStore = HostStore()
    @State private var trustStore = TrustedHostStore()
    @State private var discovery = DeviceDiscovery()

    var body: some Scene {
        // Root window: the saved-hosts list. `Window` (singular) —
        // not `WindowGroup` — because we want a strict single-
        // instance scene. `WindowGroup` permits multiple instances
        // and `openWindow(id:)` spawns a new one each call, which
        // breaks the "Window > Hosts" / dock-icon-reopen flow.
        // `Window`'s `openWindow(id:)` brings the existing instance
        // forward instead.
        Window("Hosts", id: "hosts") {
            HostsView()
                .environment(hostStore)
                .environment(trustStore)
                .environment(discovery)
                .onAppear { discovery.start() }
        }
        .defaultSize(width: 520, height: 420)
        .commands { RegiCommands() }

        // One window per connected host. Spawned by openWindow(value:)
        // from HostsView with a KVMSessionWindowID. Each window owns
        // its own Session so multiple hosts can be connected at the
        // same time. The window id carries all the connection info
        // it needs — saved hosts and discovered (mDNS) hosts both
        // route through here without HostStore lookup.
        WindowGroup("KVM Session", for: KVMSessionWindowID.self) { $sessionID in
            if let id = sessionID {
                KVMSessionWindow(sessionID: id)
                    // Per-host trust opt-ins persist via TrustedHostStore
                    // so a "Trust certificate" click from one window
                    // applies to every future window for the same host
                    // (saved or mDNS-discovered).
                    .environment(trustStore)
                    // 16:9 video at minWidth=800 wants ~525pt of
                    // video height (plus toolbar / status strip).
                    // The previous minHeight=600 floored the shrink-
                    // resize from KVMVideoView and left letterbox
                    // bars. 400 accommodates 16:9 and most 21:9
                    // ultrawide displays without going absurdly
                    // small.
                    .frame(minWidth: 800, minHeight: 400)
            } else {
                // No valid id — typically a window macOS tried to
                // restore from a previous launch (the system "Reopen
                // windows on logon" path), where our Codable wrapper
                // refused to decode. SwiftUI still spawns the window
                // with a nil binding; self-dismiss it so the user
                // doesn't see an empty session window flash.
                OrphanSessionWindowDismisser()
            }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

private struct OrphanSessionWindowDismisser: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .onAppear { dismissWindow() }
    }
}

extension Session.State.Phase {
    var label: String {
        switch self {
        case .checkingStatus: return "Checking device…"
        case .authenticating: return "Authenticating…"
        case .signaling: return "Opening signaling channel…"
        case .offering: return "Negotiating WebRTC offer…"
        case .awaitingAnswer: return "Waiting for answer…"
        case .iceGathering: return "Establishing connection…"
        }
    }
}
