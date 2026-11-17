import ATAppSync
import Foundation

/// What Sync settings says about trust between this instance and a peer
/// when it only goes one way. Trust is directed: each instance decides for
/// itself. Local network sync and sending sign-ins need both directions:
/// an instance only asks peers it trusts for changes, and only answers
/// peers that it trusts. Account (PDS) sync doesn't depend on trust.
struct PeerTrustExplanation: Equatable {
    enum Direction: Equatable {
        /// This instance trusts the peer; the peer hasn't trusted it back
        /// yet (as far as this instance has heard).
        case onlyThisInstanceTrusts
        /// This instance trusts the peer, but the peer distrusts it.
        case peerDistrustsThisInstance
        /// The peer trusts this instance; this instance doesn't trust it.
        case onlyPeerTrusts
    }

    let direction: Direction
    let title: String
    /// What syncs, and what doesn't, in this state.
    let detail: String
    /// What fixes it.
    let fix: String

    /// Nil when trust is mutual, or absent both ways (the ordinary
    /// "not verified" or "distrusted" states say enough).
    init?(state: AppSyncPeerTrustState, inbound: AppSyncInboundTrust, accountSync: Bool) {
        let thisTrusts: Bool
        switch state {
        case .directlyTrusted, .indirectlyTrusted: thisTrusts = true
        case .local: return nil
        case .explicitlyDistrusted, .implicitlyDistrusted, .unknown: thisTrusts = false
        }
        let account = accountSync
            ? " Changes still sync between them through your account."
            : ""
        switch (thisTrusts, inbound) {
        case (true, .trustsThisInstance), (false, .unknown), (false, .distrustsThisInstance):
            return nil
        case (true, .unknown):
            direction = .onlyThisInstanceTrusts
            title = "Not yet trusted back"
            detail = "This instance trusts it, but it hasn’t trusted this instance yet, so they don’t sync with each other on the local network and sign-ins can’t be sent between them. If you just verified it, this clears after its next sync." + account
            fix = "Verify again from either instance (compare emoji, or scan its code) so each trusts the other."
        case (true, .distrustsThisInstance):
            direction = .peerDistrustsThisInstance
            title = "It doesn’t trust this instance"
            detail = "This instance trusts it, but it distrusted this instance, so they don’t sync with each other on the local network and sign-ins can’t be sent between them." + account
            fix = "Verify again from either instance (compare emoji, or scan its code) so each trusts the other; or distrust it here too."
        case (false, .trustsThisInstance):
            direction = .onlyPeerTrusts
            title = "Trusts this instance, but isn’t trusted here"
            detail = "It trusts this instance, but this instance doesn’t trust it, so they don’t sync with each other on the local network and sign-ins can’t be sent between them." + account
            fix = "Verify it here (compare emoji, or scan its code) if it’s yours; otherwise distrust it."
        }
    }
}
