import Foundation
import XCTest

/// Every write of persisted state goes through PlatformSupport's
/// `AtomicFile` (whole files, moves) or `AppendLog` (append-only logs), or is
/// one SQLite statement or transaction. A write that bypasses them can leave
/// a file half written when the disk fills or the app is killed, so this
/// fails on any file API that writes, outside the few places that are
/// atomic another way, each with its reason.
final class AtomicWriteLintTests: XCTestCase {
    private static let banned: [(name: String, pattern: String)] = [
        ("Data/String write", #"\.write\(to:"#),
        ("write(toFile:)", #"write\(toFile:"#),
        ("atomically:", #"atomically:"#),
        ("createFile", #"\bcreateFile\(atPath:"#),
        ("FileHandle for writing", #"FileHandle\(for(WritingTo|Updating|WritingAtPath|UpdatingAtPath)"#),
        ("FileHandle write", #"\.write\(contentsOf:"#),
        ("moveItem", #"\bmoveItem\("#),
        ("replaceItem", #"\breplaceItem(At)?\("#),
        ("copyItem", #"\bcopyItem\("#),
        ("open for writing", #"\bO_(RDWR|WRONLY)\b"#),
        ("truncate", #"\b(ftruncate\(|truncate\(atOffset)"#),
        ("fopen", #"\bfopen\("#),
    ]

    /// Places that write another way, and why that is atomic.
    private static let allowed: [String: (names: Set<String>, reason: String)] = [
        "Sources/HummingbirdKit/Core/Player/VOD/MediaCache.swift": (
            ["createFile", "FileHandle for writing", "FileHandle write", "truncate"],
            "media bytes at their offsets; synced before the atomically written metadata lists them, and dropped from it before truncation"
        ),
        "Sources/HummingbirdKit/Core/Player/UMPMediaCache.swift": (
            ["open for writing", "truncate"],
            "preallocated, memory-mapped media; msync'd before the atomically written index lists a range"
        ),
        "Apps/iOS/BackgroundCallBench.swift": (
            ["createFile", "FileHandle for writing"],
            "a diagnostic trace in the temporary directory, not app state"
        ),
    ]

    func testPersistedStateIsOnlyWrittenAtomically() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rules = try Self.banned.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var violations: [String] = []
        for directory in ["Sources", "Apps", "Packages/ATAppSync/Sources"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return XCTFail("Could not read \(base.path)")
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                let exemptions = Self.allowed[relative]?.names ?? []
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    let range = NSRange(code.startIndex..., in: code)
                    for (name, rule) in rules where !exemptions.contains(name)
                        && rule.firstMatch(in: code, range: range) != nil {
                        violations.append("\(relative):\(index + 1): \(name)")
                    }
                }
            }
        }
        XCTAssertEqual(violations, [], "Write persisted state with AtomicFile or AppendLog (PlatformSupport)")
    }

    /// The allowlist names only places that still need it.
    func testEveryExemptionIsStillUsed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (path, exemption) in Self.allowed {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for name in exemption.names {
                let pattern = try XCTUnwrap(Self.banned.first { $0.name == name }).pattern
                let rule = try NSRegularExpression(pattern: pattern)
                XCTAssertNotNil(rule.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                                "\(path) no longer needs its \(name) exemption")
            }
        }
    }
}
