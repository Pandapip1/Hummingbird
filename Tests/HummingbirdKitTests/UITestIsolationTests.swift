import Foundation
import XCTest

/// UI tests drive the real app, so they must never launch it on real data.
/// Only `IsolatedApp` (Tests/UITestSupport) may create an `XCUIApplication`;
/// it gives every launch a data root of its own. Launches go through
/// `IsolatedApp.launch()` or `IsolatedApp.start(_:)` too, which retry a launch
/// the system failed to start; only the reference apps launch directly.
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
                where line.contains("XCUIApplication(") || Self.launchesDirectly(line) {
                    offenders.append("\(directory)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "launch the app with IsolatedApp.launch() or IsolatedApp.start(_:)")
    }

    private static func launchesDirectly(_ line: String) -> Bool {
        line.contains(".launch()") && !line.contains("IsolatedApp.launch()") && !line.contains("safari.launch()")
    }
}
