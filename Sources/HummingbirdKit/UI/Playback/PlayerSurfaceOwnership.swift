import Foundation

/// Exactly one surface shows a player at a time.
///
/// Every mounted surface (the inline view, the full-screen presentation)
/// registers a claim; the most recent one owns the player and is the only one
/// attached to it. A new owner attaches before the previous one detaches, so
/// the same player moves between surfaces without a gap (no pause, no seek, no
/// audio glitch). When the owner goes away, the claim before it attaches
/// again. A surface never attaches on its own, so a stale or hidden one
/// cannot render a second copy of the video.
@MainActor
final class PlayerSurfaceOwnership {
    /// One surface's way to show and stop showing the player.
    final class Claim {
        let name: String
        fileprivate let attach: @MainActor () -> Void
        fileprivate let detach: @MainActor () -> Void

        init(name: String, attach: @escaping @MainActor () -> Void, detach: @escaping @MainActor () -> Void) {
            self.name = name
            self.attach = attach
            self.detach = detach
        }
    }

    private var claims: [Claim] = []
    private(set) var owner: Claim?

    /// Surfaces attached to the player right now: never more than one.
    var attachedCount: Int { owner == nil ? 0 : 1 }

    /// A surface appeared (or came back): it takes the player.
    func claim(_ claim: Claim) {
        claims.removeAll { $0 === claim }
        claims.append(claim)
        handOver(to: claim)
    }

    /// A surface went away: the one claimed before it takes the player back.
    func resign(_ claim: Claim) {
        claims.removeAll { $0 === claim }
        guard owner === claim else { return }
        if let previous = claims.last {
            handOver(to: previous)
        } else {
            owner = nil
            claim.detach()
        }
    }

    /// Re-applies the owner's attachment (the player object changed).
    func refresh() { owner?.attach() }

    private func handOver(to claim: Claim) {
        guard owner !== claim else { return }
        let previous = owner
        claim.attach()
        owner = claim
        previous?.detach()
    }
}
