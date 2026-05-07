import Foundation

/// Wire types for the JSON-RPC methods the macOS client uses.
/// Source-of-truth is the server-side handlers in
/// `jsonrpc.go:1243` and the Go structs they return.

// MARK: - ATX power

/// Action argument for `setATXPowerAction`. Note the kebab-case wire
/// values — server-side switch is at `jsonrpc.go:793-808`.
public enum ATXPowerAction: String, Codable, Sendable, CaseIterable {
    /// 200ms power-button press. Triggers a clean shutdown / power-on
    /// from most BIOS/UEFI ATX implementations.
    case powerShort = "power-short"
    /// 5-second power-button hold. Force-power-off.
    case powerLong = "power-long"
    /// 200ms reset-button press.
    case reset = "reset"
}

/// Result of `getATXState` — the host's front-panel LED states.
public struct ATXState: Codable, Sendable, Equatable {
    public let power: Bool
    public let hdd: Bool

    public init(power: Bool, hdd: Bool) {
        self.power = power
        self.hdd = hdd
    }
}

// MARK: - Video codec preference

/// Argument and return type for the codec preference RPCs.
public enum VideoCodecPreference: String, Codable, Sendable, CaseIterable {
    case auto
    case h264
    case h265
}

// MARK: - Video state

/// Result of `getVideoState`. Mirrors `internal/native/video.go` —
/// `streaming` is an enum on the server side but the wire type is a
/// string so we treat it as one and don't enumerate values.
public struct VideoState: Codable, Sendable, Equatable {
    public let ready: Bool
    public let streaming: String
    public let error: String?
    public let width: Int
    public let height: Int
    public let fps: Double

    public init(
        ready: Bool,
        streaming: String,
        error: String? = nil,
        width: Int,
        height: Int,
        fps: Double
    ) {
        self.ready = ready
        self.streaming = streaming
        self.error = error
        self.width = width
        self.height = height
        self.fps = fps
    }
}

// MARK: - Failsafe

/// Payload of the `failsafeMode` server-pushed notification
/// (`failsafe.go:26-29`). When `active` is true the device is in
/// failsafe mode and the user should be alerted; `reason` is a
/// human-readable string for the banner.
public struct FailsafeModeNotification: Codable, Sendable, Equatable {
    public let active: Bool
    public let reason: String

    public init(active: Bool, reason: String) {
        self.active = active
        self.reason = reason
    }
}
