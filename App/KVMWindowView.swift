import SwiftUI
import JetKVMTransport
import WebRTC

struct KVMWindowView: View {
    @Environment(Session.self) private var session
    @State private var capturer = KeyboardCapturer()
    @State private var pointerLock = PointerLockManager()
    @State private var hostKey = HostKeyDetector()
    @State private var keyboardMonitor: Any?
    @State private var showControls = false
    @State private var showStats = false

    /// UserDefaults key for the "Don't show this again" preference on
    /// the pointer-lock confirmation dialog.
    private static let skipPointerLockConfirmKey = "JetKVMSkipPointerLockConfirmation"

    private var keyboardCaptureBinding: Binding<Bool> {
        Binding(
            get: { capturer.userIntent },
            set: { newValue in
                if newValue { capturer.enable() } else { capturer.disable() }
            }
        )
    }

    private var pointerLockBinding: Binding<Bool> {
        Binding(
            get: { pointerLock.userIntent },
            set: { newValue in
                if newValue {
                    requestPointerLockEnable()
                } else {
                    pointerLock.disable()
                }
            }
        )
    }

    /// Reflects the union of intents — used to label and icon the
    /// toolbar Capture menu.
    private var captureSummary: (icon: String, label: String) {
        switch (capturer.userIntent, pointerLock.userIntent) {
        case (false, false): return ("keyboard", "Capture")
        case (true, false):  return ("keyboard.fill", "Capture: kbd")
        case (false, true):  return ("cursorarrow.rays", "Capture: ptr")
        case (true, true):   return ("dot.viewfinder", "Capture: kbd+ptr")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let track = session.videoTrack {
                    KVMVideoRepresentable(
                        track: track,
                        session: session,
                        pointerLocked: pointerLock.state == .enabled
                    )
                } else {
                    ProgressView("Waiting for video…")
                        .controlSize(.large)
                        .foregroundStyle(.white)
                }
                // Stack of top-of-window banners. Most-severe first.
                VStack(spacing: 8) {
                    if case .kicked = session.state {
                        banner(
                            "Another peer connected to this device — your session was taken over.",
                            background: .red,
                            foreground: .white
                        )
                    }
                    if case .reconnecting(let attempt) = session.state {
                        banner(
                            "Connection lost — reconnecting (attempt \(attempt))…",
                            background: .orange,
                            foreground: .black
                        )
                    }
                    if let failsafe = session.failsafe, failsafe.active {
                        banner(
                            "Device is in failsafe mode: \(failsafe.reason)",
                            background: .red,
                            foreground: .white
                        )
                    }
                    if case .awaitingAccessibility = capturer.state {
                        banner(
                            "Grant Accessibility permission to capture system shortcuts (Cmd+Tab, Cmd+Space, …), then click Capture again.",
                            background: .yellow,
                            foreground: .black
                        )
                    }
                    Spacer()
                }
                .padding()
            }
            StatusStrip()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let device = session.device {
                    Text(device.deviceID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle(isOn: keyboardCaptureBinding) {
                        Label("Keyboard lock", systemImage: "keyboard")
                    }
                    Toggle(isOn: pointerLockBinding) {
                        Label("Pointer lock", systemImage: "cursorarrow.rays")
                    }
                } label: {
                    Label(captureSummary.label, systemImage: captureSummary.icon)
                }
                .help("Capture system keyboard shortcuts (Cmd+Tab, Cmd+Space, …) and/or lock the pointer for relative mouse mode. Keyboard requires Accessibility permission.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showControls.toggle()
                } label: {
                    Label("Controls", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showControls, arrowEdge: .top) {
                    ControlPanel()
                        .environment(session)
                }
                .disabled(!session.rpcReady)
                .help("Power, codec, and quality controls.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStats.toggle()
                } label: {
                    Label("Stats", systemImage: "chart.line.uptrend.xyaxis")
                }
                .popover(isPresented: $showStats, arrowEdge: .top) {
                    StatsPanel()
                        .environment(session)
                }
                .help("Live network and video diagnostics.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect") {
                    Task { await session.disconnect() }
                }
            }
        }
        .onAppear {
            // Wire capturer event handlers into the same Session methods
            // KVMVideoView calls when the tap isn't installed. Same
            // contract: keyCode is the macOS Carbon virtual keycode.
            // Each handler also feeds HostKeyDetector so the ⌃⌥ release
            // chord works while keyboard-lock is on (the trapped case
            // — with keyboard-lock off, the user can already exit
            // pointer-lock via Cmd+Tab → focus loss → auto-suspend).
            capturer.onKeyDown = { [session, hostKey] keyCode in
                hostKey.didKeyDown(keyCode)
                session.sendKeypress(virtualKeyCode: keyCode, pressed: true)
            }
            capturer.onKeyUp = { [session, hostKey] keyCode in
                hostKey.didKeyUp(keyCode)
                session.sendKeypress(virtualKeyCode: keyCode, pressed: false)
            }
            capturer.onFlagsChanged = { [session] keyCode in
                session.handleFlagsChanged(virtualKeyCode: keyCode)
            }
            capturer.onModifierFlagsChanged = { [hostKey] flags in
                hostKey.didChangeFlags(flags)
            }
            // When capture pauses (focus loss or user toggling off
            // mid-keystroke), release any modifiers the tracker thinks
            // are held on the host. Without this, e.g. a Cmd-down sent
            // before a focus-out and a Cmd-up that the system swallowed
            // would leave the host with a stuck Cmd modifier.
            capturer.onSuspend = { [session, hostKey] in
                session.releaseAllHeldModifiers()
                hostKey.reset()
            }
            hostKey.onTriggered = { [pointerLock] in
                guard pointerLock.state == .enabled else { return }
                pointerLock.disable()
            }
            // Second feed path: an NSEvent local monitor catches
            // keyboard events delivered through the standard responder
            // chain — the path used when keyboard-lock is off (CGEventTap
            // not installed). When keyboard-lock IS on, events are
            // swallowed at the session-level tap before they reach the
            // WindowServer, so the monitor doesn't double-fire.
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .keyUp]
            ) { [hostKey] event in
                switch event.type {
                case .flagsChanged:
                    hostKey.didChangeFlags(event.modifierFlags)
                case .keyDown:
                    hostKey.didKeyDown(event.keyCode)
                case .keyUp:
                    hostKey.didKeyUp(event.keyCode)
                default:
                    break
                }
                return event
            }
        }
        .onDisappear {
            capturer.disable()
            pointerLock.disable()
            hostKey.reset()
            if let monitor = keyboardMonitor {
                NSEvent.removeMonitor(monitor)
                keyboardMonitor = nil
            }
        }
    }

    private func requestPointerLockEnable() {
        if UserDefaults.standard.bool(forKey: Self.skipPointerLockConfirmKey) {
            pointerLock.enable()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Lock pointer to JetKVM?"
        alert.informativeText = """
            Your cursor will be hidden and pinned to this window, and mouse \
            movement sent as relative deltas to the device.

            To release the lock, press and hold ⌃⌥ (Control + Option) for half \
            a second.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Lock pointer")
        alert.addButton(withTitle: "Cancel")
        let checkbox = NSButton(
            checkboxWithTitle: "Don't show this again",
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if checkbox.state == .on {
            UserDefaults.standard.set(true, forKey: Self.skipPointerLockConfirmKey)
        }
        pointerLock.enable()
    }

    /// Top-of-window banner used for kicked / failsafe / accessibility
    /// states. All read better as a pinned strip than a popup, so we
    /// stack them at the top of the video view.
    private func banner(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .foregroundStyle(foreground)
            .cornerRadius(6)
    }
}

private struct KVMVideoRepresentable: NSViewRepresentable {
    let track: RTCVideoTrack
    let session: Session
    let pointerLocked: Bool

    func makeNSView(context: Context) -> KVMVideoView {
        let view = KVMVideoView()
        view.setSession(session)
        view.pointerLocked = pointerLocked
        view.attach(track: track)
        return view
    }

    func updateNSView(_ nsView: KVMVideoView, context: Context) {
        nsView.setSession(session)
        nsView.pointerLocked = pointerLocked
        nsView.attach(track: track)
    }

    static func dismantleNSView(_ nsView: KVMVideoView, coordinator: ()) {
        nsView.detach()
    }
}
