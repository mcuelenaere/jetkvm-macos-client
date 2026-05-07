import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "app.jetkvm.client", category: "tap")

/// Manages a session-level `CGEventTap` so the app can swallow
/// system-grabbed key combos (Cmd+Tab, Cmd+Q, Cmd+Space, etc.) and
/// forward them to the JetKVM host instead.
///
/// Capture has two layers of state:
///  - `userIntent`: what the toolbar toggle reflects.
///  - `state`: whether the tap is actually installed right now.
///
/// They diverge when the app loses focus: `userIntent` stays `true`
/// but `state` flips to `.suspended` (tap removed) so we don't grab
/// system shortcuts while the user is in another app. When focus
/// returns we re-install the tap automatically. This matters for
/// modifier state, too — `onSuspend` fires when active capture pauses
/// so the owner can release held modifiers on the host (otherwise
/// the host ends up thinking Cmd is still held after the user
/// alt-tabbed away).
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
        case enabled    // tap installed AND user intends capture
        case suspended  // user intends capture, tap removed (app not active)
        case failed(String)
    }

    private(set) var state: State = .disabled

    /// Tracks whether the user has the toolbar toggle on. Capture
    /// suspends/resumes around app focus changes, but `userIntent`
    /// persists across them.
    private(set) var userIntent: Bool = false

    /// Set by the owner to receive forwarded key events. Each closure
    /// is invoked on the main thread — same context the tap runs on
    /// (we register the tap source on the main run loop).
    var onKeyDown: ((UInt16) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    var onFlagsChanged: ((UInt16) -> Void)?

    /// Fires when an active tap is suspended — either the user
    /// toggled off, or the app lost focus while capture was on. Use
    /// this to release any modifiers your tracker thinks are held,
    /// so the host doesn't end up with stuck-down keys.
    var onSuspend: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var notificationObservers: [NSObjectProtocol] = []

    init() {
        // Watch for app focus changes so we can suspend/resume the
        // tap automatically. NSApp-level (not NSWindow-level) is
        // appropriate — CGEventTap is global, so when our app isn't
        // frontmost we shouldn't be intercepting system shortcuts at
        // all.
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appResignedActive() }
        })
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
    }

    // No deinit cleanup: deinit runs nonisolated and we can't read
    // MainActor-isolated state from there. Owners (KVMWindowView)
    // call `disable()` from `.onDisappear` to tear the tap down. If
    // we ever leak this object the tap stays installed until process
    // exit — acceptable given the audience and lifetime.

    func toggle() {
        if userIntent {
            disable()
        } else {
            enable()
        }
    }

    /// Express "user wants capture on". If the app is currently
    /// active and Accessibility is granted, the tap installs and
    /// `state` becomes `.enabled`. Otherwise `state` reflects the
    /// blocking condition (`.awaitingAccessibility` or `.suspended`).
    func enable() {
        log.info("user enabled capture")
        userIntent = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Bool] = [promptKey: true]
        guard AXIsProcessTrustedWithOptions(options as CFDictionary) else {
            log.notice("Accessibility permission not granted yet")
            state = .awaitingAccessibility
            return
        }
        if NSApp.isActive {
            installTap()
        } else {
            // App not frontmost yet — wait for didBecomeActive.
            state = .suspended
        }
    }

    /// Express "user wants capture off". Tears down the tap (if
    /// installed) and clears `userIntent` so we don't auto-resume on
    /// the next app-active notification.
    func disable() {
        let wasActiveCapture: Bool = (state == .enabled)
        userIntent = false
        teardownTap()
        state = .disabled
        if wasActiveCapture {
            onSuspend?()
        }
    }

    private func teardownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // Notification handlers — wire app focus changes through to the
    // tap state. userIntent is the source of truth for "should this
    // tap exist when the app is active?"
    private func appResignedActive() {
        guard userIntent else { return }
        let wasActiveCapture = (state == .enabled)
        teardownTap()
        state = .suspended
        if wasActiveCapture {
            log.info("app resigned active → tap suspended; releasing held modifiers")
            // Tell the owner so it can release any modifiers the
            // tracker thinks are held — otherwise the host gets a
            // stuck Cmd / Shift / etc.
            onSuspend?()
        }
    }

    private func appBecameActive() {
        guard userIntent, state != .enabled else { return }
        log.info("app became active → re-installing tap")
        // Re-check Accessibility — the user may have granted it
        // manually while we were away.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            state = .awaitingAccessibility
            return
        }
        installTap()
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
            log.error("CGEvent.tapCreate returned nil — Accessibility permission may have been revoked")
            state = .failed("Failed to install event tap")
            return
        }
        log.info("CGEventTap installed")

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
                log.notice("event tap auto-disabled (\(type.rawValue, privacy: .public)) — re-enabling")
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
