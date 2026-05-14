# Backlog

Things we've consciously deferred. Each entry should carry enough context
to be picked up cold without re-litigating the original investigation.

---

## Improve scroll performance for trackpads (e.g. MacBook Pro)

**Symptom:** trackpad scrolling on the host feels chunky and
bursty. A real scroll wheel feels fine — it fires at ~5-10
detents/sec, one tick per detent. macOS trackpads fire
`NSEvent.scrollWheel` at 60-120Hz, and our per-event JSON-RPC
`wheelReport` (`Session.sendWheelReport` →
`Session+RPC.sendWheelReportRPC`) eats real time on encode +
WebRTC SCTP transit + decode + dispatch on the host. TigerVNC's
VNC fork doesn't exhibit this on the same hardware because its
wheel path is an in-process call — no per-tick parsing overhead.

**Two paths, roughly cheapest first:**

1. **Client-side coalescing in `KVMVideoView.scrollWheel`.**
   Accumulate deltas over a ~16ms window, fire one `wheelReport`
   per window with the summed deltas. JetKVM's web frontend
   already does this (its `scrollThrottling` setting). Pure
   client change, no server impact, probably enough on its own.

2. **Binary HID-RPC opcode for wheel.** `internal/hidrpc/hidrpc.go`
   already defines `TypeWheelReport = 0x04` but the dispatch is
   missing from `handleHidRPCMessage`'s switch — every wheel
   tick takes the JSON-RPC slow path instead. A two-byte binary
   frame over the unreliable-ordered HID channel would skip JSON
   entirely. Requires an upstream JetKVM patch; client side is
   ~3 small edits in `JetKVMProtocol/Codec/HIDRPCMessage.swift`,
   `Session.sendWheelReport`, and `KVMVideoView.scrollWheel`.

Measure before doing both — coalescing alone may close the gap.

---

## Clipboard sync between client and host (feasibility limited)

**Why this is harder for a hardware KVM than for a VM.** All the
mainstream "shared clipboard" solutions in virtualization stacks
rely on a **guest agent running inside the VM** plus an
out-of-band channel between hypervisor and that agent:

- **VirtualBox:** Guest Additions provide the clipboard service
  via the VirtualBox driver IPC.
- **VMware Workstation/Fusion:** VMware Tools' `vmtoolsd` exposes
  clipboard via the VMCI socket family.
- **Parallels Desktop:** Parallels Tools, same pattern.
- **KVM/QEMU + SPICE:** `spice-vdagent` running inside the guest
  exchanges clipboard frames with the SPICE server over a virtio
  serial port.
- **Hyper-V:** Integration Services include a "Heartbeat /
  Time / KV exchange / Shutdown / Clipboard" set of services with
  matching guest-side daemons.
- **RDP / Citrix:** Both protocols define a clipboard virtual
  channel that the remote desktop server multiplexes over the
  session transport.

**JetKVM is a hardware KVM**, not a VM — there's no agent we can
ship onto the host. Our only path to the host is USB-HID. So the
canonical "shared clipboard" architecture doesn't apply.

**The realistic option is one-way "paste-as-keystrokes" (host ←
client only).** Read `NSPasteboard.general.string(forType: .string)`,
translate the resulting string into a sequence of USB-HID
keystrokes, send via the JetKVM `executeKeyboardMacro` JSON-RPC
method (`TypeKeyboardMacroReport = 0x07` exists in the binary
HID-RPC enum but isn't dispatched there; JSON-RPC is the working
path).

**Limitations of the keystrokes-as-paste approach:**

- Plain text only — no rich text, images, files, or non-Unicode.
- Sensitive to keyboard-layout mismatch. Our client knows macOS
  layout; the host's USB-HID interpretation depends on its own
  active layout. Sending `"é"` as Option-E might land as something
  else if the host's layout differs.
- International characters that aren't on the keymap (`KeyMap.swift`)
  drop or need composition — the macro system supports modifier +
  key but not arbitrary Unicode.
- No copy-FROM-host (the host has no way to push its clipboard to
  us — that's exactly the agent role we don't have).
- Slow on long pastes — every character is a HID-RPC frame.

**Implementation sketch (when we get to it):**

1. Cmd+Shift+V (or a toolbar / menu entry) reads the macOS
   clipboard string.
2. A new `App/PasteAsKeystrokes.swift` translates the string to
   `[KeyboardMacroStep]` (a struct already used by
   `executeKeyboardMacro`). One step per character, modifier
   bitmask + USB-HID usage ID. Special-case Return / Tab / Space.
3. `Session.sendPasteMacro(_:)` calls `executeKeyboardMacro`
   over JSON-RPC.
4. UI surfaces progress (count of frames sent) for long pastes,
   with a Cancel that fires `cancelKeyboardMacro`.

**Out of scope:** anything resembling a true bidirectional
clipboard would require a host-side helper app, which is a
significant scope expansion (signed installer, auto-launch,
update mechanism, per-OS variants for macOS / Linux / Windows
hosts). Worth noting only as a non-goal.

---

## Move WebRTC pin back to upstream `stasel/WebRTC` once M148+ releases

**Where:** `Packages/JetKVMTransport/Package.swift` and
`Regi.xcodeproj/project.pbxproj` (the project carries its
own `XCRemoteSwiftPackageReference` — both pins have to match or
SPM errors on conflicting package identity).

**What's there now:** both pins point at
`https://github.com/AttilaTheFun/WebRTC.git` at `148.0.0`. That's
a personal fork carrying the fix from
[stasel/WebRTC#147](https://github.com/stasel/WebRTC/pull/147) —
the missing per-class headers on the macOS slice that broke every
release from M141 to M147 (see stasel/WebRTC#145). The fork
builds clean, runtime smoke test against real hardware works.

**Why move back:** depending on a personal fork is a supply-chain
wart — no guarantee `AttilaTheFun` keeps publishing future
milestones, repo could disappear, no community review of any
behavioral changes vs. upstream. Cleanest fix is for #147 to
merge upstream and `stasel/WebRTC` to ship M148 (or higher) from
the merged tree.

**What "fixed" looks like:**

1. Track stasel/WebRTC tags. When 148.0.0 (or 149+) lands on
   `stasel/WebRTC`, swap both pins back:
   - `Packages/JetKVMTransport/Package.swift` — restore the
     `https://github.com/stasel/WebRTC.git` URL.
   - `Regi.xcodeproj/project.pbxproj` — same URL +
     version on the `XCRemoteSwiftPackageReference`.
2. Delete the `Package.resolved` files (both the workspace one
   under `.../swiftpm/Package.resolved` and the package-level
   one under `Packages/JetKVMTransport/`) and re-resolve so the
   new revision hash is recorded.
3. Build + run the same smoke test (status → device → login →
   WS → ICE → video) to confirm parity.
4. Drop the "Temporarily on AttilaTheFun's fork" TODO comment
   in `Packages/JetKVMTransport/Package.swift`.
