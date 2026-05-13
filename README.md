<p align="center">
  <img src="docs/logo.png" alt="Regi" width="120">
</p>

# Regi

[![Build](https://github.com/mcuelenaere/regi/actions/workflows/build.yml/badge.svg)](https://github.com/mcuelenaere/regi/actions/workflows/build.yml)

A native macOS client for [JetKVM](https://jetkvm.com) hardware.

<p align="center">
  <img src="docs/screenshots/hero.jpg" alt="Regi hosts list and a connected session" width="820">
</p>

## What it is

JetKVM ships a web-based control panel that runs in a browser tab and
works fine for casual remote-control. But a browser can't capture
macOS system shortcuts — ⌘Tab, ⌘Space, ⌘Q — so they get eaten by your
Mac instead of reaching the host. Regi is a native macOS app that
fixes this and a handful of other rough edges along the way.

It speaks the same WebRTC + JSON-RPC + HID-RPC protocol as the
official frontend; the difference is in the macOS integration around
it.

## Features

- **Real keyboard capture.** System shortcuts — ⌘Tab, ⌘Space (Spotlight),
  ⌘Q, ⌘H, Mission Control, function keys — route to the remote host via
  `CGEventTap`. Engages automatically when the session window is
  frontmost; suspends the moment you switch apps so your Mac isn't
  fighting you.
- **mDNS / Bonjour discovery.** JetKVM devices on your LAN appear in
  the host list automatically — no URL typing, no scanning.
- **Multi-window, multi-device.** Connect to several JetKVMs at once,
  each in its own window with its own video stream, signaling channel,
  and session state.
- **Pointer lock for FPS / CAD work.** Optional mode that pins the
  cursor and delivers raw relative motion, so the host cursor doesn't
  walk away from yours on multi-monitor host setups.
- **In-app TLS trust prompt.** Default JetKVM certs are self-signed.
  Regi surfaces a one-time "Trust certificate" prompt with the actual
  failure reason instead of a generic browser warning, and remembers
  your choice per host.
- **Keychain-backed passwords.** Per-host, scoped to the app.
- **Bandwidth gate.** When the session window is minimised or fully
  covered, Regi tells the device to pause its encoder (after a 5 s
  debounce). Saves device CPU and LAN bandwidth while the window's
  hidden; resumes instantly when you bring it back.
- **First-class native UI.** SwiftUI, Mission Control thumbnails,
  Window menu entries with each host's display name, native
  fullscreen, real app icon in the Dock.


## Differences vs. the JetKVM web frontend

| | JetKVM web UI | Regi |
|---|---|---|
| System shortcuts (⌘Tab, ⌘Q, ⌘Space, …) | macOS swallows them | Forwarded to the host |
| Find devices on the LAN | Type the URL | Auto-discovery via mDNS |
| Multiple devices | One browser tab each | Multiple native windows |
| Self-signed cert | Browser security warning | In-app trust prompt |
| Window minimised / occluded | Keeps streaming | Pauses encoder (5 s debounce) |
| Passwords | Browser autofill (if remembered) | macOS Keychain |
| Pointer lock | HTML5 Pointer Lock API | Native CG APIs |
| Updates | Browser cache | Standalone `.app` |

What Regi *doesn't* replace: anything that's not part of an active
remote-control session. The device's setup flow, advanced settings,
firmware updates, and so on are still done through the web UI. Regi
assumes you've configured the device there at least once.

## Requirements

- macOS 14 (Sonoma) or later
- A JetKVM device reachable on the network
- For HTTPS to default-config devices: JetKVM firmware that produces
  RFC 5280-compliant certificate serial numbers (recent firmware does;
  older firmware still works over plain HTTP, and the in-app trust
  prompt handles the self-signed CA either way)

## Installation

Grab `Regi.dmg` from the [latest release](https://github.com/mcuelenaere/regi/releases/latest) and drag `Regi.app` into `/Applications`. A bare `Regi.zip` is on the same release page if you'd rather skip the disk image.

> [!NOTE]
> Regi isn't currently signed by an Apple-trusted developer ID, so macOS Gatekeeper refuses the first launch with *"can't be opened because Apple cannot check it for malicious software."* Bypass once and macOS remembers your choice:
>
> - **Finder**: right-click `Regi.app` → **Open** → confirm in the dialog. Subsequent double-clicks work normally.
> - **Terminal**: `xattr -d com.apple.quarantine /Applications/Regi.app`

### Building from source

```sh
git clone https://github.com/mcuelenaere/regi.git
cd regi
open Regi.xcodeproj
```

Hit ⌘R in Xcode.

## About the name

Regi is Esperanto for *to rule*, *to govern*, *to take control* —
which is, roughly, what a KVM client does. You point it at a remote
machine and you're in charge: keyboard, mouse, screen. The name is
short, pronounceable in most languages (*REH-ghee*), and has no prior
tech-product baggage.

## License

Apache 2.0 — see [LICENSE](LICENSE).

## Acknowledgements

- The [JetKVM project](https://github.com/jetkvm/kvm) for the hardware
  and the open firmware Regi talks to.
- [`stasel/WebRTC`](https://github.com/stasel/WebRTC) for the
  WebRTC.framework SwiftPM distribution.
