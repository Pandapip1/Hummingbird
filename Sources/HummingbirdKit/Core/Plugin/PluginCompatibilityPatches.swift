import Foundation

/// Version-indexed source patches for known plugin bugs. The fixes themselves
/// are bundled as ordinary unified diffs so they remain inspectable and can be
/// tested against the exact plugin source they target.
enum PluginCompatibilityPatches {
    struct Result {
        let script: String
        let applied: [String]
        let failed: [String]
    }

    private struct Patch {
        let pluginID: String
        let version: Int
        let name: String
        let resource: String
    }

    private static let patches = [
        Patch(
            pluginID: "35ae969a-a7db-11ed-afa1-0242ac120002",
            version: 366,
            name: "youtube-native-ump-legacy-path",
            resource: "youtube-366-native-ump-legacy-path"
        ),
    ]

    static func apply(pluginID: String, version: Int, original: String) -> Result {
        var script = original
        var applied: [String] = []
        var failed: [String] = []
        for patch in patches where patch.pluginID == pluginID && patch.version == version {
            guard let url = Bundle.module.url(
                forResource: patch.resource,
                withExtension: "diff",
                subdirectory: "CompatibilityPatches"
            ) else {
                failed.append("\(patch.name):resource-missing")
                continue
            }
            do {
                let diff = try String(contentsOf: url, encoding: .utf8)
                script = try UnifiedDiff.apply(diff, to: script)
                applied.append(patch.name)
            } catch {
                failed.append("\(patch.name):\(error)")
            }
        }
        return Result(script: script, applied: applied, failed: failed)
    }
}

enum UnifiedDiff {
    enum Error: Swift.Error {
        case malformedHunk
        case contextNotFound
    }

    /// Applies the hunks of a unified diff by matching their full old-side
    /// context. Line coordinates are informative; exact context is authoritative.
    static func apply(_ diff: String, to source: String) throws -> String {
        let lineEnding = source.contains("\r\n") ? "\r\n" : "\n"
        // Use substring separation rather than Character-based `split`: Swift
        // treats CRLF as one grapheme, so splitting it on the LF Character does
        // not produce lines.
        var sourceLines = source.components(separatedBy: "\n").map { $0.trimmingSuffix("\r") }
        let diffLines = diff.components(separatedBy: "\n").map { $0.trimmingSuffix("\r") }
        var index = 0
        var sawHunk = false

        while index < diffLines.count {
            guard diffLines[index].hasPrefix("@@") else {
                index += 1
                continue
            }
            sawHunk = true
            index += 1
            var old: [String] = []
            var new: [String] = []
            while index < diffLines.count, !diffLines[index].hasPrefix("@@") {
                let line = diffLines[index]
                if line.isEmpty, index == diffLines.count - 1 {
                    index += 1
                    break
                }
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") { break }
                guard let marker = line.first else { throw Error.malformedHunk }
                let content = String(line.dropFirst())
                switch marker {
                case " ": old.append(content); new.append(content)
                case "-": old.append(content)
                case "+": new.append(content)
                case "\\": break
                default: throw Error.malformedHunk
                }
                index += 1
            }
            guard !old.isEmpty,
                  let range = firstRange(of: old, in: sourceLines) else {
                throw Error.contextNotFound
            }
            sourceLines.replaceSubrange(range, with: new)
        }
        guard sawHunk else { throw Error.malformedHunk }
        return sourceLines.joined(separator: lineEnding)
    }

    private static func firstRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle { return start..<end }
        }
        return nil
    }
}

private extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        last == suffix ? String(dropLast()) : self
    }
}
