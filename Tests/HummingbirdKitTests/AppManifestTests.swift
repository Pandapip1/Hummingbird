import Foundation
import XCTest

/// Xcode (project.yml) and xtool (xtool.yml, Package.swift) build the app from
/// files generated out of Apps/AppManifest.swift, so both produce the same
/// Hummingbird.app. This fails while any of those files is out of date.
final class AppManifestTests: XCTestCase {
    func testGeneratedAppDefinitionsAreUpToDate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/generate-app")
        process.arguments = ["--check"]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, message)
    }
}
