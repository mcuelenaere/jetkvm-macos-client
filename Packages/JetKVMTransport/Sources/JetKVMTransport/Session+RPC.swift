import Foundation
import JetKVMProtocol

/// Typed wrappers for the JSON-RPC methods the control plane needs.
///
/// All methods are gated on `rpcReady` — calling before the channel
/// has fully opened throws `SessionError.rpcNotReady` rather than
/// hanging waiting for a response that can't ride the channel.
extension Session {

    // MARK: - Identity

    public func getDeviceID() async throws -> String {
        try await rpcCall(method: "getDeviceID")
    }

    // MARK: - ATX power

    public func setATXPowerAction(_ action: ATXPowerAction) async throws {
        struct Params: Encodable, Sendable { let action: String }
        try await rpcNotify(method: "setATXPowerAction", params: Params(action: action.rawValue))
    }

    public func getATXState() async throws -> ATXState {
        try await rpcCall(method: "getATXState")
    }

    // MARK: - Video codec preference

    public func getVideoCodecPreference() async throws -> VideoCodecPreference {
        try await rpcCall(method: "getVideoCodecPreference")
    }

    public func setVideoCodecPreference(_ codec: VideoCodecPreference) async throws {
        struct Params: Encodable, Sendable { let codec: String }
        try await rpcNotify(method: "setVideoCodecPreference", params: Params(codec: codec.rawValue))
    }

    // MARK: - Stream quality

    public func getStreamQualityFactor() async throws -> Double {
        try await rpcCall(method: "getStreamQualityFactor")
    }

    public func setStreamQualityFactor(_ factor: Double) async throws {
        struct Params: Encodable, Sendable { let factor: Double }
        try await rpcNotify(method: "setStreamQualityFactor", params: Params(factor: factor))
    }

    // MARK: - State

    public func getVideoState() async throws -> VideoState {
        try await rpcCall(method: "getVideoState")
    }

    public func getUSBState() async throws -> String {
        try await rpcCall(method: "getUSBState")
    }

    // MARK: - Convenience: initial state fetch + optimistic updates

    /// Fetch every cached control-plane field in parallel. Called
    /// automatically when the rpc channel becomes ready; can also be
    /// invoked manually by a UI refresh button.
    public func refreshControlState() async {
        guard rpcReady else { return }

        async let video = try? getVideoState()
        async let usb = try? getUSBState()
        async let atx = try? getATXState()
        async let factor = try? getStreamQualityFactor()
        async let codec = try? getVideoCodecPreference()

        videoState = await video
        usbState = await usb
        atxState = await atx
        streamQualityFactor = await factor
        videoCodecPreference = await codec
    }

    /// Optimistically update the cached factor and send the setter.
    /// On failure, refresh from the server to restore truth.
    public func updateStreamQualityFactor(_ factor: Double) async {
        streamQualityFactor = factor
        do {
            try await setStreamQualityFactor(factor)
        } catch {
            streamQualityFactor = try? await getStreamQualityFactor()
        }
    }

    public func updateVideoCodecPreference(_ codec: VideoCodecPreference) async {
        videoCodecPreference = codec
        do {
            try await setVideoCodecPreference(codec)
        } catch {
            videoCodecPreference = try? await getVideoCodecPreference()
        }
    }

    // MARK: - Internal helpers

    private func rpcCall<R: Decodable & Sendable>(
        method: String,
        params: some Encodable & Sendable = EmptyParams()
    ) async throws -> R {
        guard let rpc, rpcReady else { throw SessionError.rpcNotReady }
        return try await rpc.call(method: method, params: params)
    }

    private func rpcNotify(
        method: String,
        params: some Encodable & Sendable = EmptyParams()
    ) async throws {
        guard let rpc, rpcReady else { throw SessionError.rpcNotReady }
        try await rpc.notify(method: method, params: params)
    }
}
