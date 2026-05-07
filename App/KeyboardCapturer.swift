import AppKit
import ApplicationServices
import CoreGraphics

/// Manages a session-level `CGEventTap` so the app can swallow
/// system-grabbed key combos (Cmd+Tab, Cmd+Q, Cmd+Space, etc.) and
/// forward them to the JetKVM host instead.
///
/// Requires Accessibility permission. The first call to `enable()`
/// triggers macOS's system prompt; if the user grants it, the tap
/// installs and `state` flips to `.enabled`. If the prompt is
/// dismissed without granting, `state` becomes `.awaitingAccessibility`
/// — the user has to grant manually in System Settings → Privacy &
/// Security → Accessibility, then call `enable()` again.
///
/// **The app must be unsandboxed** for CGEventTap to work; App Sandbox
/// blocks session-level taps outright. Our build is unsandboxed for
/// this reason (commit 1: ENABLE_HARDENED_RUNTIME stays off in debug).
@MainActor
@Observable
final class KeyboardCapturer {
    enum State: Equatable {
        case disabled
        case awaitingAccessibility
        case enabled
        case failed(String)
    }

    private(set) var state: State = .disabled

    /// Set by the owner to receive forwarded key events. Each closure
    /// is invoked on the main thread — same context the tap runs on
    /// (we register the tap source on the main run loop).
    var onKeyDown: ((UInt16) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    var onFlagsChanged: ((UInt16) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {}

    // No deinit cleanup: deinit runs nonisolated and we can't read
    // MainActor-isolated state from there. Owners (KVMWindowView)
    // call `disable()` from `.onDisappear` to tear the tap down. If
    // we ever leak this object the tap stays installed until process
    // exit — acceptable given the audience and lifetime.

    func toggle() {
        switch state {
        case .enabled: disable()
        case .disabled, .awaitingAccessibility, .failed: enable()
        }
    }

    func enable() {
        if case .enabled = state { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Bool] = [promptKey: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            state = .awaitingAccessibility
            return
        }
        installTap()
    }

    func disable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if case .failed = state { return } // preserve failure state
        state = .disabled
    }

    private func installTap() {
        let mask: CGEventMask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // The C callback is @convention(c) — it can't capture Swift
        // state. Pass `self` as opaque userInfo and unwrap inside.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<KeyboardCapturer>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            state = .failed("Failed to install event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        state = .enabled
    }

    /// Tap callback. Marked `nonisolated` so it can be called from the
    /// `@convention(c)` callback; we registered the run loop source on
    /// the main run loop, so this fires on the main thread and using
    /// `MainActor.assumeIsolated` is safe.
    private nonisolated func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            // Only swallow when our app is the frontmost. Otherwise
            // we'd grab Cmd+Tab system-wide, which is rude.
            guard NSApp.isActive else {
                return Unmanaged.passUnretained(event)
            }

            switch type {
            case .keyDown, .keyUp, .flagsChanged:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                switch type {
                case .keyDown: onKeyDown?(keyCode)
                case .keyUp: onKeyUp?(keyCode)
                case .flagsChanged: onFlagsChanged?(keyCode)
                default: break
                }
                return nil // swallow

            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                // The system auto-disables a tap that's too slow or
                // the user deliberately suspended. Re-enable so the
                // user doesn't have to flip our toggle off-and-on.
                if let tap = eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)

            default:
                return Unmanaged.passUnretained(event)
            }
        }
    }
}
