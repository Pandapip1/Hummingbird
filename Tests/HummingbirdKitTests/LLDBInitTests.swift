import Foundation
import XCTest

/// The scheme's LLDB init file runs at every debug launch. LLDB's `script`
/// prints the value of a final bare expression, which is how a stray
/// "False" appeared at the top of every launch's console.
final class LLDBInitTests: XCTestCase {
    func testScriptLinesPrintNothing() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/lldb/lldbinit")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let scripts = lines.filter { $0.hasPrefix("script ") }
        XCTAssertFalse(scripts.isEmpty)
        for line in scripts {
            let last = line.dropFirst("script ".count)
                .split(separator: ";").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let isStatement = last.hasPrefix("import ") || last.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#,
                                                                       options: .regularExpression) != nil
            XCTAssertTrue(isStatement, "this would print its value at every launch: \(last)")
        }
    }
}
