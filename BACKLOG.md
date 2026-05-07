# Backlog

Things we've consciously deferred. Each entry should carry enough context
to be picked up cold without re-litigating the original investigation.

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
