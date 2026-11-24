import Foundation
import XCTest

/// AVKit's player view, left interactive, takes the remote's focus and keeps
/// it (tvOS): no control over the video can be reached. The app makes player
/// view controllers only through `AVPlayerViewController.pictureOnly()`.
final class PlayerSurfaceConstructionTests: XCTestCase {
    func testPlayerViewControllersAreMadeOnlyAsPictures() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var constructions: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated()
            where line.contains("AVPlayerViewController()") {
                constructions.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(constructions.count, 1,
                       "make player views with AVPlayerViewController.pictureOnly(); found \(constructions)")
    }
}
