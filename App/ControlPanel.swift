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

/// Compact single-line strip showing video + USB state. Lives at
/// the bottom of the KVM window so the user has ambient awareness
/// of the connection without opening the controls popover.
struct StatusStrip: View {
    @Environment(Session.self) private var session

    var body: some View {
        HStack(spacing: 12) {
            if let video = session.videoState {
                Label {
                    Text("\(video.width)×\(video.height) @ \(Int(video.fps.rounded())) fps")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "display")
                }
                if let err = video.error, !err.isEmpty {
                    Text(err.replacingOccurrences(of: "_", with: " "))
                        .foregroundStyle(.red)
                }
            } else {
                Text("Video: …")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let usb = session.usbState {
                Label(usb, systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}
