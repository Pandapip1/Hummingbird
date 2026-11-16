import Foundation
import Synchronization
import XCTest
#if canImport(Glibc)
import Glibc
#endif

/// Fails the test run if anything changes the user's real Hummingbird data:
/// the real Application Support (Linux: `~/.local/share`) and Caches
/// `Hummingbird` directories, and the real UserDefaults domains.
///
/// This is the second line of defence. The first is in HummingbirdKit itself:
/// in a test process the real locations do not exist (`LiveData`), so state
/// a test forgot to inject stops the process before anything is written.
/// This guard also catches writes that bypass HummingbirdKit's stores.
///
/// `HummingbirdTestBootstrap` installs it when the test bundle loads, before
/// the first test, so no test class has to opt in. It records a baseline of
/// metadata only (paths, sizes, modification times, preference values); it
/// never writes. Each test then ends with a comparison against it, which
/// fails that test with a list of what changed; a change made after the last
/// test fails the whole run.
final class RealDataGuard: NSObject, XCTestObservation, Sendable {
    private let baseline: Mutex<RealDataSnapshot>
    private let lateChange = Mutex<String?>(nil)

    private init(baseline: RealDataSnapshot) {
        self.baseline = Mutex(baseline)
    }

    static func install() {
        XCTestObservationCenter.shared.addTestObserver(RealDataGuard(baseline: .current()))
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        // Teardown blocks run last-in, first-out, so this one, added before
        // the test runs, runs after the test's own cleanup.
        testCase.addTeardownBlock { [self] in
            if let change = takeChange() {
                XCTFail("This test changed the user's real Hummingbird data:\n\(change)")
            }
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        guard let change = takeChange() else { return }
        let message = "error: the test run changed the user's real Hummingbird data after its last test:\n\(change)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }

    /// What changed since the baseline, if anything; the current state
    /// becomes the new baseline so each change is reported once.
    private func takeChange() -> String? {
        let current = RealDataSnapshot.current()
        return baseline.withLock { baseline in
            guard current != baseline else { return nil }
            defer { baseline = current }
            return current.differences(from: baseline).joined(separator: "\n")
        }
    }
}

@_cdecl("hummingbird_install_real_data_guard")
public func installRealDataGuard() {
    RealDataGuard.install()
}

/// Metadata of the user's real Hummingbird data. Reading it never writes.
struct RealDataSnapshot: Equatable, Sendable {
    struct FileState: Equatable, Sendable {
        let size: Int
        let modified: Date?
    }

    var files: [String: FileState] = [:]
    /// Each watched domain in a canonical text form, or nil when it does not exist.
    var preferences: [String: String] = [:]

    /// The application's domains on each platform, and this process's own
    /// (`UserDefaults.standard` in a test).
    static var watchedPreferenceDomains: [String] {
        let processDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        return Array(Set(["com.eightybps.Hummingbird", "Hummingbird-gtk", processDomain])).sorted()
    }

    static var watchedDirectories: [URL] {
        [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory].compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first?
                .appendingPathComponent("Hummingbird", isDirectory: true)
        }
    }

    static func current() -> RealDataSnapshot {
        var snapshot = RealDataSnapshot()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for directory in watchedDirectories {
            var items = [directory]
            if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) {
                for case let url as URL in enumerator { items.append(url) }
            }
            for url in items {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                snapshot.files[url.path] = FileState(size: values.fileSize ?? 0, modified: values.contentModificationDate)
            }
        }
        for domain in watchedPreferenceDomains {
            snapshot.preferences[domain] = UserDefaults.standard.persistentDomain(forName: domain).map(canonical)
        }
        return snapshot
    }

    func differences(from earlier: RealDataSnapshot) -> [String] {
        var lines: [String] = []
        for path in Set(files.keys).union(earlier.files.keys).sorted() {
            switch (earlier.files[path], files[path]) {
            case (nil, .some): lines.append("  created  \(path)")
            case (.some, nil): lines.append("  removed  \(path)")
            case let (before?, after?) where before != after: lines.append("  modified \(path)")
            default: break
            }
        }
        for domain in Set(preferences.keys).union(earlier.preferences.keys).sorted()
        where preferences[domain] != earlier.preferences[domain] {
            lines.append("  changed  UserDefaults domain \(domain)")
        }
        return lines
    }
}

/// A property list as text with dictionary keys sorted, so equal values
/// compare equal however they were read.
private func canonical(_ value: Any) -> String {
    switch value {
    case let dictionary as [String: Any]:
        "{" + dictionary.keys.sorted().map { "\($0)=\(canonical(dictionary[$0] as Any))" }.joined(separator: ";") + "}"
    case let array as [Any]:
        "[" + array.map(canonical).joined(separator: ",") + "]"
    default:
        String(describing: value)
    }
}
