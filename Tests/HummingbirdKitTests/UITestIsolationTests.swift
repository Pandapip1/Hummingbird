import Foundation
import XCTest

/// UI tests drive the real app, so they must never launch it on real data.
/// Only `IsolatedApp` (Tests/UITestSupport) may create an `XCUIApplication`;
/// it gives every launch a data root of its own.
final class UITestIsolationTests: XCTestCase {
    func testUITestsLaunchTheAppOnlyThroughIsolatedApp() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for directory in ["HummingbirdIOSUITests", "HummingbirdTVUITests"] {
            let folder = tests.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated()
                where line.contains("XCUIApplication(") {
                    offenders.append("\(directory)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "launch the app with IsolatedApp.make() or IsolatedApp.launch()")
    }
}

/// UI tests name debug scenes and identifiers through `UITestContract.swift`,
/// which they compile too: a scene that is renamed or removed (as the
/// media-less "player" scene was) breaks their build, not their run.
final class UITestContractTests: XCTestCase {
    func testUITestsNameDebugScenesOnlyThroughTheContract() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for directory in ["HummingbirdIOSUITests", "HummingbirdTVUITests", "UITestSupport"] {
            let folder = tests.appendingPathComponent(directory)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated()
                where line.contains("\"HUMMINGBIRD_DEBUG_SCENE\"") {
                    offenders.append("\(directory)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "launch a scene with IsolatedApp.make(scene:)")
    }
}
