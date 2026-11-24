import ATAppSync
import Foundation

/// One at-rest sealer for the whole test run, so files reopened by later
/// instances (a simulated relaunch) open with the same key.
let testAtRestSealer = AtRestSealer.ephemeral(purpose: "tests")

/// The keyring tests' stores use: keys in memory only.
let testAtRestKeyring = AtRestKeyring.ephemeral()

struct UnreadableSealedJournal: Error {}

/// A journal sealed with `testAtRestSealer`, opened back into the plain JSON
/// object a version from before sealing wrote, so tests can make the files
/// older versions left behind.
func plaintextJournalObject(at file: URL) throws -> [String: Any] {
    guard let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
        throw UnreadableSealedJournal()
    }
    func open(_ base64: Any, context: String) throws -> Any {
        guard let sealed = (base64 as? String).flatMap({ Data(base64Encoded: $0) }),
              case .opened(let data) = testAtRestSealer.open(sealed, context: context) else {
            throw UnreadableSealedJournal()
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    guard var object = try open(stored["meta"] as Any, context: "meta") as? [String: Any] else {
        throw UnreadableSealedJournal()
    }
        object["events"] = try (stored["events"] as? [Any] ?? []).map { try open($0, context: "event") }
    object["pending"] = try (stored["pending"] as? [Any] ?? []).map { try open($0, context: "pending") }
    return object
}
