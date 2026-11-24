import Foundation
import XCTest

/// AdvancedVideoPlayerKit expresses one behaviour; platform differences live
/// in SwiftOpenUI's backends (MediaScrubber, PresentationMenu, the remote focus
/// modifiers, CheckableMenuItem).
final class PlayerKitPortabilityTests: XCTestCase {
    func testPlayerKitHasNoPlatformBranches() throws {
        let kit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AdvancedVideoPlayerKit")
        let files = try FileManager.default.contentsOfDirectory(at: kit, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("#if os("), "\(file.lastPathComponent) branches by platform; use a SwiftOpenUI API")
        }
    }
}
