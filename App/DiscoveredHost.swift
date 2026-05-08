import Foundation

/// A JetKVM device discovered via mDNS / Bonjour. Distinct from
/// SavedHost — discovered entries are ephemeral (vanish when the
/// device leaves the network) and not user-named.
struct DiscoveredHost: Hashable, Identifiable {
    /// Bonjour service instance name (user-visible label set by the
    /// device, e.g. "JetKVM (a1b2)").
    let instanceName: String
    /// Resolved hostname without trailing dot, e.g. "jetkvm-abcd.local".
    let host: String
    /// TCP port. JetKVM publishes 443 when TLS is on, 80 otherwise.
    let port: Int
    /// True iff the published port is 443.
    let useTLS: Bool
    /// `id` TXT record from the advertisement. Optional in case
    /// older firmware doesn't publish it.
    let deviceID: String?
    /// `version` TXT record.
    let version: String?
    /// `setup` TXT record. False means the device isn't provisioned
    /// yet — connecting to it would land on the setup wizard.
    let isSetup: Bool

    var id: String { instanceName }

    var displayName: String { instanceName }
}
