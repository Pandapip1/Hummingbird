import ATAppSync
import Foundation

/// The user's real, per-user locations: Application Support (on Linux,
/// `$XDG_DATA_HOME`), Caches, the app's own UserDefaults domain and the
/// system keychain.
///
/// Nothing reaches these except through `AppDataStores.live`, which only an
/// application entry point calls; everything else receives its stores. In a
/// test process the real locations do not exist: asking for one stops the
/// process with a message naming what was asked for. A test that forgot to
/// inject a store therefore fails loudly instead of writing into the
/// developer's own profile, library or keychain.
enum LiveData {
    /// Whether this process is a test runner rather than the application
    /// (shared with ATAppSync; see `TestProcess`).
    static var isTestProcess: Bool { TestProcess.isRunning }

    /// Stops a test process that reached for real user data.
    static func require(_ location: @autoclosure () -> String) {
        guard isTestProcess else { return }
        fatalError("""
            A test reached \(location()). Tests must never read or write the user's real data: \
            inject an AppDataStores made for the test (makeTestStores()) instead.
            """)
    }

    /// The per-user Application Support directory (`~/.local/share` on Linux).
    static func applicationSupportDirectory() -> URL {
        require("the real Application Support directory")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The per-user Caches directory (`~/.cache` on Linux).
    static func cachesDirectory() -> URL {
        require("the real Caches directory")
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// The environment variable that lets tests use the system keychain.
    static let systemKeychainTestsVariable = "HUMMINGBIRD_SYSTEM_KEYCHAIN_TESTS"

    /// Whether the person running the tests opted in to tests that use the
    /// system keychain (macOS Data Protection and login keychains, or the
    /// Secret Service on Linux) with `HUMMINGBIRD_SYSTEM_KEYCHAIN_TESTS=1`.
    static var systemKeychainTestsEnabled: Bool {
        ProcessInfo.processInfo.environment[systemKeychainTestsVariable] == "1"
    }

    /// Stops a test that opened the system keychain, unless the run opted in
    /// and the test uses its own service: `tests.` followed by something
    /// unique to the test. So no test can read, change or delete an item
    /// under Hummingbird's own services, whatever it does with the store.
    static func requireTestKeychainAccess(serviceNamespace namespace: String?) {
        guard isTestProcess else { return }
        guard systemKeychainTestsEnabled else {
            fatalError("""
                A test opened the system keychain. Tests use FakeKeychainBackend or an in-memory \
                CredentialStore; set \(systemKeychainTestsVariable)=1 to run the opt-in keychain tests.
                """)
        }
        guard let namespace, namespace.hasPrefix("tests."), namespace.count > "tests.".count else {
            fatalError("""
                A test opened the system keychain under the service namespace \
                \(namespace.map { "\"\($0)\"" } ?? "of the app itself"). Use a per-test namespace \
                such as "tests.<UUID>".
                """)
        }
    }
}

/// A UserDefaults domain. It is named rather than held, so stores that refer
/// to one can cross actors (UserDefaults itself is not Sendable).
public enum PreferencesDomain: Sendable, Hashable {
    /// The application's own domain, `UserDefaults.standard`. Unavailable in
    /// a test process.
    case standard
    /// A separate suite, such as the one each test gets.
    case suite(String)

    public var defaults: UserDefaults {
        switch self {
        case .standard:
            LiveData.require("the app's UserDefaults domain (UserDefaults.standard)")
            return .standard
        case .suite(let name):
            guard let defaults = UserDefaults(suiteName: name) else {
                preconditionFailure("\"\(name)\" cannot name a UserDefaults suite")
            }
            return defaults
        }
    }
}
