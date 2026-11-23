import Foundation
import XCTest
@testable import HummingbirdKit

/// One surface shows the player at a time, across every transition, and a
/// handover attaches the new surface before the old one lets go.
@MainActor
final class PlayerSurfaceOwnershipTests: XCTestCase {
    private var attached: Set<String> = []
    private var events: [String] = []
    private var maximum = 0

    private func claim(_ name: String) -> PlayerSurfaceOwnership.Claim {
        PlayerSurfaceOwnership.Claim(name: name, attach: { [unowned self] in
            attached.insert(name); events.append("+\(name)"); maximum = max(maximum, attached.count)
        }, detach: { [unowned self] in
            attached.remove(name); events.append("-\(name)")
        })
    }

    func testAtMostOneSurfaceAcrossTabsOverviewFullscreenPictureInPictureAndRotation() {
        let surfaces = PlayerSurfaceOwnership()
        let inline = claim("inline")
        surfaces.claim(inline)

        // Tab switch away and back: the page stays mounted; nothing changes.
        XCTAssertEqual(surfaces.attachedCount, 1)
        // Rotation and layout: updates never attach (only claims do).
        surfaces.refresh()
        XCTAssertEqual(attached, ["inline"])

        // Full screen in: the new surface attaches, then the inline one lets go.
        events.removeAll()
        let fullscreen = claim("fullscreen")
        surfaces.claim(fullscreen)
        XCTAssertEqual(events, ["+fullscreen", "-inline"])
        XCTAssertEqual(attached, ["fullscreen"])

        // Full screen out: the inline surface attaches first, then full screen goes.
        events.removeAll()
        surfaces.resign(fullscreen)
        XCTAssertEqual(events, ["+inline", "-fullscreen"])
        XCTAssertEqual(attached, ["inline"])

        // Picture in Picture uses the owner's layer: no new surface.
        XCTAssertEqual(surfaces.owner?.name, "inline")

        // A rebuilt page view (overview, layout) claims; the old view resigns.
        let rebuilt = claim("rebuilt")
        surfaces.claim(rebuilt)
        surfaces.resign(inline)
        XCTAssertEqual(attached, ["rebuilt"])

        // The last surface going away detaches the player.
        surfaces.resign(rebuilt)
        XCTAssertEqual(attached, [])
        XCTAssertEqual(surfaces.attachedCount, 0)
        XCTAssertLessThanOrEqual(maximum, 2, "only during a handover, never at rest")
        XCTAssertEqual(maximum, 2, "the new surface attaches before the old one detaches")
    }
}
