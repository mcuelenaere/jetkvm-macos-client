import SwiftUI
import JetKVMProtocol
import JetKVMTransport

/// Popover content with ATX power buttons, codec preference, and
/// stream quality slider. Fed by Session's cached control-plane
/// state — Session refreshes once when the rpc channel opens.
struct ControlPanel: View {
    @Environment(Session.self) private var session
    @State private var showResetConfirm = false
    @State private var showPowerLongConfirm = false
    @State private var pendingError: String?

    private var rpcDisabled: Bool { !session.rpcReady }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            powerSection
            Divider()
            codecSection
            Divider()
            qualitySection
            if let err = pendingError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Power

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Power").font(.headline)
                Spacer()
                if let atx = session.atxState {
                    Label(
                        atx.power ? "On" : "Off",
                        systemImage: atx.power ? "circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(atx.power ? .green : .secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Power") {
                    Task { await runAction { try await session.setATXPowerAction(.powerShort) } }
                }
                .disabled(rpcDisabled)

                Button("Reset…") {
                    showResetConfirm = true
                }
                .disabled(rpcDisabled)
                .confirmationDialog(
                    "Reset host?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task { await runAction { try await session.setATXPowerAction(.reset) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Sends the reset signal to the host.")
                }

                Button("Force Off…") {
                    showPowerLongConfirm = true
                }
                .disabled(rpcDisabled)
                .confirmationDialog(
                    "Force-power off?",
                    isPresented: $showPowerLongConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Force Off", role: .destructive) {
                        Task { await runAction { try await session.setATXPowerAction(.powerLong) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Holds the power button for 5 seconds.")
                }
            }
        }
    }

    // MARK: - Codec

    private var codecSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codec preference").font(.headline)
            Picker(
                "Codec",
                selection: Binding(
                    get: { session.videoCodecPreference ?? .auto },
                    set: { newValue in
                        Task { await session.updateVideoCodecPreference(newValue) }
                    }
                )
            ) {
                Text("Auto").tag(VideoCodecPreference.auto)
                Text("H.264").tag(VideoCodecPreference.h264)
                Text("H.265").tag(VideoCodecPreference.h265)
            }
            .pickerStyle(.segmented)
            .disabled(rpcDisabled || session.videoCodecPreference == nil)
            Text("Takes effect on next reconnect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Quality

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stream quality").font(.headline)
                Spacer()
                if let factor = session.streamQualityFactor {
                    Text(String(format: "%.0f%%", factor * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Slider(
                value: Binding(
                    get: { session.streamQualityFactor ?? 1.0 },
                    set: { newValue in
                        Task { await session.updateStreamQualityFactor(newValue) }
                    }
                ),
                in: 0.1...1.0,
                step: 0.1
            )
            .disabled(rpcDisabled || session.streamQualityFactor == nil)
        }
    }

    // MARK: - Helpers

    private func runAction(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            pendingError = nil
        } catch {
            pendingError = "\(error)"
        }
    }
}

/// Compact single-line strip showing the host video + USB state at
/// the bottom of the KVM window. Each segment is only rendered when
/// we have data to show — empty segments collapse rather than
/// rendering a "Loading…" placeholder.
struct StatusStrip: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            videoSection
            Spacer()
            usbSection
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var videoSection: some View {
        if let video = session.videoState {
            HStack(spacing: 6) {
                Image(systemName: "display")
                // Text(verbatim:) bypasses LocalizedStringKey, which would
                // otherwise insert the locale's thousand separator into
                // 1920 / 1080.
                Text(verbatim: "\(video.width)×\(video.height) \(Int(video.fps.rounded())) fps")
                    .monospacedDigit()
                // The canonical "is the host pipeline broken" signal is
                // `error` (no_signal / no_lock / out_of_range per the
                // server-side struct comment); `streaming` tracks a
                // different internal state machine that doesn't always
                // line up with whether frames are flowing.
                if let err = video.error, !err.isEmpty {
                    Text(err.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.red)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usbSection: some View {
        if let usb = session.usbState {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector")
                Text(verbatim: "USB \(friendlyUSBState(usb))")
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Map raw Linux UDC state strings to friendlier client-facing
    /// labels. `configured` is the USB-spec "fully enumerated and
    /// working" state — calling it "connected" matches the user's
    /// mental model better than the kernel's vocabulary.
    private func friendlyUSBState(_ raw: String) -> String {
        switch raw {
        case "configured": return "connected"
        case "addressed", "default", "powered", "attached", "connected":
            return "connecting"
        case "suspended": return "suspended"
        case "disconnected", "not attached": return "disconnected"
        default: return raw
        }
    }
}
