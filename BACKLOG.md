# Backlog

Things we've consciously deferred. Each entry should carry enough context
to be picked up cold without re-litigating the original investigation.

---

## mDNS device discovery (requires upstream JetKVM change)

**Where (client):** new `App/DeviceDiscovery.swift` (or similar) using
`NWBrowser(for: .bonjour(type: "_jetkvm._tcp", domain: nil), …)` on
the connect screen. Each `NWBrowser.Result` would surface as a row
in the device list with hostname + IP; the user picks one instead
of typing the hostname.

**Why blocked:** JetKVM uses `pion/mdns` purely as an mDNS responder
— it answers A/AAAA queries for `jetkvm.local` (registered as a
LocalName at `internal/mdns/mdns.go:134`) but does **not** broadcast
a Bonjour PTR/SRV/TXT record for `_jetkvm._tcp`. Without that,
`NWBrowser` returns zero results; there's nothing on the wire to
discover. Hard-coded probing of likely hostnames (`jetkvm.local`,
`kvm.local`, etc.) would work but is fragile and doesn't generalize
to renamed devices.

**Upstream fix sketch:** `internal/mdns/mdns.go` already initializes
`pion_mdns.Server` with the device's local names. Adding service
advertisement requires either:
  1. Switching to a library that advertises Bonjour services
     (e.g., `hashicorp/mdns` has `mdns.NewServer(*MDNSService)`
     where `MDNSService` carries instance/service/host/port/TXT),
     or
  2. Manually publishing the PTR (`_jetkvm._tcp.local.` → instance),
     SRV (instance → host:port), and TXT records via raw DNS-SD
     records on the existing pion connection.

Either way, the JetKVM web server's listener already knows its
port (80 by default), so the SRV record is straightforward. TXT
could carry firmware version / setup mode / capabilities — useful
for the discovery UI to show "needs setup" or filter compatible
versions.

Once upstream advertises, our `NWBrowser` consumer is ~30 lines:
hold a Set of results, render them in a `List` in `ConnectView`
above the manual host field, on tap fill the host field +
auto-connect.

---

## Remove the explicit "Capture" toolbar toggle (auto-engage)

**Where:** `App/KVMWindowView.swift` (toolbar item),
`App/KeyboardCapturer.swift` (toggle/state machine),
`App/KVMVideoView.swift` (mouse-in-view tracking).

**What's there now:** the user has to click a "Capture" toolbar
toggle the first time to grant Accessibility permission and engage
the CGEventTap. After that, focus-loss / focus-gain auto-suspends
and resumes the tap, so the toggle is a one-time-per-session
gesture once permission is granted.

**Why remove it:** the toggle is a UX wart. The user's mental model
is "I'm in the JetKVM window, all my keystrokes go to the host;
I'm somewhere else, they don't" — exactly what the auto-pause
already does on app focus. The explicit toggle adds a step.

**Proposed model:** capture engages automatically whenever
(a) the JetKVM window is the key window, **and**
(b) the mouse cursor is inside the `KVMVideoView`.
Disengages when either is false. No toolbar item.

The "mouse in view" condition is the safety hatch for cases where
the user wants to use system shortcuts on the client without losing
the connection — they nudge the cursor outside the view (or to the
title bar) and Cmd+Tab works normally.

**Implementation outline:**
1. `KVMVideoView`: track mouse-in-view via `mouseEntered` /
   `mouseExited`, with an `NSTrackingArea` covering bounds. Forward
   transitions to a callback.
2. `KeyboardCapturer`: replace `userIntent` with the AND of
   "window is key" and "mouse in view"; both are external inputs
   driven by the view layer.
3. First-run Accessibility prompt: trigger the system prompt the
   first time `KVMWindowView` appears with a connected session,
   not on toolbar click. If denied, fall back to in-window-only
   capture (no CGEventTap), with a banner explaining the limitation
   and a "Grant…" button that re-prompts.
4. Drop the toolbar toggle.

---

## True fullscreen mode that hides the menu bar

**Where:** `App/JetKVMClientApp.swift` (Scene/WindowGroup config),
maybe a new `App/Window/FullscreenController.swift`.

**What's there now:** the WindowGroup uses default macOS fullscreen
(green button → window goes fullscreen, menu bar auto-hides on
no-cursor and shows on cursor-to-top-of-screen). For a KVM the
auto-show is the wrong default — it eats the top row of the host's
display every time the user nudges the mouse upward.

**Goal:** when the window is fullscreen, the menu bar stays hidden
*even on cursor-at-top*, so the host's full resolution is visible
1:1 the entire time. The Dock should also stay hidden.

**Approach:**
1. Use `NSApplication.shared.presentationOptions` to set
   `[.autoHideMenuBar, .autoHideDock]` (or `.hideMenuBar` /
   `.hideDock` for permanent — pick the one that matches the
   "even on hover" intent; I think the `hide*` variants are
   permanent and `autoHide*` are the always-show-on-hover ones).
2. Apply when the window enters fullscreen, revert on exit.
   `NSWindow.willEnterFullScreenNotification` /
   `willExitFullScreenNotification` are the hooks.
3. Probably also worth pinning the cursor to the video rect while
   fullscreen + capture is on, so the host cursor doesn't drift
   into the now-invisible menu bar area at the top.

**Don't break the non-fullscreen path** — only apply the
presentation options while in fullscreen.

---

## Scroll wheel support (requires upstream JetKVM change)

**Where (client):** `App/KVMVideoView.swift` would override
`scrollWheel(with: NSEvent)` and forward to a new
`Session.sendScroll(deltaY:)` that emits a HID-RPC wheel frame on
the unreliable-ordered channel.
`Packages/JetKVMProtocol/Sources/JetKVMProtocol/Codec/HIDRPCMessage.swift`
intentionally omits a `wheelReport` case today — that comment is the
thing to update once the wire format is settled.

**Where (server):** `internal/hidrpc/hidrpc.go` defines
`TypeWheelReport = 0x04` but no handler exists anywhere in the
JetKVM tree. The TS UI also never sends one
(`ui/src/hooks/hidRpc.ts` declares the constant with no encoder).
Adding support, in roughly the right order:

1. **Define the wire format.** A single signed byte is sufficient
   for HID boot-mouse semantics — vertical wheel only, in HID
   "click" units (positive = scroll up). Concretely:
   `WheelReport: [deltaY: i8]`, payload size 1.
2. **Decoder.** `internal/hidrpc/message.go`: add a
   `WheelReport()` accessor returning `(deltaY int8, err)` with
   the same length-strict pattern the existing `MouseReport()`
   uses.
3. **Dispatch.** `hidrpc.go` (root): add a case for
   `TypeWheelReport` in `handleHidRPCMessage` that decodes and
   forwards to the gadget driver.
4. **Gadget driver.** `internal/usbgadget/`: most boot-mouse HID
   descriptors already include 1 byte of wheel delta after the 2
   dx/dy bytes — verify the JetKVM gadget descriptor does, then
   add a `MouseWheel(delta int8)` (or extend `MouseReport`) that
   writes a HID report with non-zero wheel and zero motion. If the
   descriptor doesn't already include the wheel field, that's a
   second sub-task: extend the descriptor and bump any version
   string the host driver might cache.

**Compatibility note.** Existing browser UI and clients don't send
`WheelReport` at all, so adding server-side support is purely
additive — old clients keep working, new clients gain scroll. No
versioning gymnastics needed.

**Client-side coalescing.** When this lands, the macOS client's
`scrollWheel` handler should accumulate `NSEvent.scrollingDeltaY`
(fractional points) into integer wheel ticks before sending — at
the native NSEvent rate, scroll generates dozens of fractional
samples per "tick" and we'd flood the gadget if we sent one HID
report per sample.

---

## Rework cookie handling to use a proper cookie jar

**Where:** `Packages/JetKVMTransport/Sources/JetKVMTransport/HTTPClient.swift`
(plus `SignalingClient.swift` which receives the resulting `Cookie:`
header value).

**What's there now:** `HTTPClient` keeps `private var cookieJar:
[String: String]`. On each response it parses `Set-Cookie` via
`HTTPCookie.cookies(withResponseHeaderFields:for:)` and stores
`name → value`. On each request it attaches a single
`Cookie: name=value; …` header by hand. URLSession's automatic cookie
machinery is explicitly disabled (`httpCookieStorage = nil`,
`httpShouldSetCookies = false`).

**Why it landed this way:** in M1 hardware testing,
`HTTPCookieStorage` (the proper API) silently dropped cookies — even
after explicit `setCookie(_:)`, `cookies(for:)` returned `nil` on the
next request and the auth cookie didn't ride along. Bypassing OS
cookie storage entirely was the fastest path to a working M1.

**Why it should be reworked:**

- Doesn't honour `Domain`, `Path`, `Secure`, `HttpOnly`, `Expires`,
  `Max-Age`, `SameSite`. JetKVM only sets one `authToken` cookie for
  one host today, so this hasn't bitten us — but anything that adds a
  second host, a path-scoped cookie, or expiry semantics will.
- Sharing with `SignalingClient` is by passing a flat string, which
  loses all attribute information. A proper jar would let the WS
  client query "give me cookies for this URL" itself.
- Thread-safety is a single `NSLock` rather than the OS-managed
  storage's queue.

**What "fixed" looks like:**

1. Diagnose why `HTTPCookieStorage` lost cookies in our setup. Hypothesis:
   `URLSessionConfiguration.ephemeral` may set up its own cookie storage
   and our override is ignored, or there's an interaction with the
   per-session delegate. A small repro (one URL session, hit a known
   `Set-Cookie` echo server, `cookies(for:)` should return it) would
   pin it down.
2. Either fix the storage configuration so the OS-managed jar works,
   or implement a small RFC-6265 jar on top of `[HTTPCookie]` (Foundation
   has `HTTPCookie` parsing; we'd own the storage and lookup logic).
3. Have `SignalingClient` query the jar for cookies for the WS URL
   instead of receiving a pre-built header string.

---

## Re-add support for JetKVM's default self-signed TLS certificate

**Where:** `Packages/JetKVMTransport/Sources/JetKVMTransport/TLSDelegate.swift`,
`DeviceEndpoint.swift`, `App/ConnectView.swift`.

**What's there now:** the connect form has an HTTPS toggle but **no**
"Trust self-signed" toggle. `DeviceEndpoint.allowSelfSignedCertificate`
is preserved as transport API but never set true. `TLSDelegate` is
installed but falls through to default trust handling.

**The bug we hit:** with HTTPS to a default-config JetKVM (self-signed
cert with the `JetKVM Self-Signed CA` issuer), Apple's
Network.framework BoringSSL fails the handshake at
`boringssl_session_set_peer_verification_state_from_session` with
"Unable to extract cached certificates from the SSL_SESSION object",
*before* the cert-verification callback hands off to URLSession's
delegate. The `[app.jetkvm.client:tls]` log category stayed empty in
testing — our delegate is never invoked, so neither
`URLCredential(trust:)` nor `SecTrustSetExceptions` ever runs. Confirmed
on macOS 26.4 with WebRTC pinned to M140 and Xcode 26.4.1.

**Things that didn't help:**

- `NSAllowsArbitraryLoads = true` in Info.plist (kept for HTTP).
- Capping `tlsMaximumSupportedProtocolVersion` to TLS 1.2 (same error;
  not a 1.3-only bug).
- Implementing both session-level and task-level
  `urlSession(_:didReceive:completionHandler:)` methods.
- `SecTrustSetExceptions` to bypass cert + hostname validation (never
  reached).

**Real fix options, roughly cheapest first:**

1. **Trust-on-first-use cert pinning.** First connection prompts the
   user to confirm the cert's SHA-256 fingerprint; we store it in
   Keychain keyed by device ID, and on subsequent connects we pin the
   exact cert. Implementing this requires bypassing URLSession's TLS
   path entirely (NWConnection with `tls_options_set_verify_block`)
   since URLSession's delegate isn't getting the chance.
2. **Bundle the JetKVM CA cert** in the app bundle and install it into
   a per-session `SecTrust` evaluation pipeline. Doesn't require user
   interaction. Needs investigation of whether Network.framework
   exposes a "use this anchor cert for this session" hook that doesn't
   trigger the same verification-callback bridge bug.
3. **Add the JetKVM CA cert to the user's keychain** at first connect
   (with explicit consent). Works with vanilla URLSession because the
   cert chain validates against the system trust store. Invasive — we'd
   modify the user's system trust state — but most reliable.

**For now:** users connect over HTTP for the LAN case (which is what
JetKVM ships with by default). The HTTPS toggle still works against a
JetKVM behind a reverse proxy with a real CA-issued cert. This is
documented in `DeviceEndpoint.allowSelfSignedCertificate`'s comment
and surfaced in the HTTPS toggle's tooltip in the UI.
