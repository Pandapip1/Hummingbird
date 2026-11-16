import ATAppSync
import CredentialStorage
import Foundation
import Synchronization

/// Every place Hummingbird keeps state that outlives the process. Each
/// window's `AppModel` and everything it creates receive these; nothing
/// finds a store of its own.
///
/// The application's entry point uses `live`, the user's real stores. Tests
/// make their own (a fresh temporary directory, a private UserDefaults suite
/// and an in-memory credential store) and never reach the real ones: in a
/// test process `live` stops the process instead (see `LiveData`).
public final class AppDataStores: Sendable {
    /// Durable data: `storage.sqlite3` (library, plugins, queue, browser
    /// sessions, caches of plugin responses), the local-profile registry and
    /// instance inboxes (`profiles/`), profile change logs (`profile-sync/`),
    /// pairing inboxes (`peer-messages/`), the permission record
    /// (`permissions/`) and debug diagnostics (`Diagnostics/`).
    public let dataDirectory: URL
    /// Disposable data: the generated-media cache.
    public let cachesDirectory: URL
    /// Device-local settings that are not synced.
    public let preferences: PreferencesDomain
    /// Plugin sign-ins, atproto sessions and AppSync instance identities.
    public let credentialStore: any CredentialStore

    let storage: Storage
    /// Serves generated media to the player, caching it in `cachesDirectory`.
    let mediaProxy: PluginMediaProxy

    public convenience init(dataDirectory: URL, cachesDirectory: URL, preferences: PreferencesDomain,
                            credentialStore: any CredentialStore) {
        self.init(dataDirectory: dataDirectory, cachesDirectory: cachesDirectory, preferences: preferences,
                  credentialStore: credentialStore, storage: Storage(directory: dataDirectory))
    }

    /// `storage` replaces `storage.sqlite3` in `dataDirectory`; tests pass an
    /// in-memory database.
    init(dataDirectory: URL, cachesDirectory: URL, preferences: PreferencesDomain,
         credentialStore: any CredentialStore, storage: Storage) {
        self.dataDirectory = dataDirectory
        self.cachesDirectory = cachesDirectory
        self.preferences = preferences
        self.credentialStore = credentialStore
        self.storage = storage
        mediaProxy = PluginMediaProxy(cache: UMPMediaCache(directory: cachesDirectory))
    }

    var defaults: UserDefaults { preferences.defaults }

    /// Holds the local-profile registry, instance inboxes and trust facts.
    var appSyncDirectory: URL { dataDirectory }
    var profileSyncDirectory: URL { dataDirectory.appendingPathComponent("profile-sync", isDirectory: true) }
    var peerMessagesDirectory: URL { dataDirectory.appendingPathComponent("peer-messages", isDirectory: true) }
    var permissionsDirectory: URL { dataDirectory.appendingPathComponent("permissions", isDirectory: true) }
    public var diagnosticsDirectory: URL {
        dataDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Waits for every pending write to `storage.sqlite3`.
    public func flush() async { await storage.flush() }

    /// The key under which the window that opens next finds its profile.
    static let localProfileIDKey = "appsync.localProfileID"

    /// The profile a window opens when it is not given one.
    var selectedLocalProfileID: UUID? {
        defaults.string(forKey: Self.localProfileIDKey).flatMap(UUID.init(uuidString:))
    }

    /// Makes `id` the profile the next window opens, after pending writes for
    /// the current profile have reached disk.
    public func selectLocalProfile(_ id: UUID) async {
        await flush()
        defaults.set(id.uuidString, forKey: Self.localProfileIDKey)
    }

    /// The legacy, device-wide pairing identity, used when no local profile's
    /// peer identity is available.
    func pairingIdentity() throws -> AppSyncPeerIdentity {
        try AppSyncPeerIdentityStore(credentialStore: credentialStore).identity()
    }

    private static let liveStores = Mutex<[String: AppDataStores]>([:])

    /// The user's real stores, shared by every window of the process.
    ///
    /// `credentialServiceNamespace` separates the keychain items of a build
    /// that is not the provisioned app (the GTK development executable).
    /// In a test process this stops the process: tests make their own stores.
    public static func live(credentialServiceNamespace: String? = nil) -> AppDataStores {
        LiveData.require("AppDataStores.live (the user's real data)")
        return liveStores.withLock { stores in
            let key = credentialServiceNamespace ?? ""
            if let existing = stores[key] { return existing }
            #if os(tvOS)
            // tvOS does not provide durable application-managed local storage.
            // Its Caches directory is the supported local home for downloaded data
            // and, unlike Application Support on tvOS, is present in the app container.
            let dataBase = LiveData.cachesDirectory()
            #else
            let dataBase = LiveData.applicationSupportDirectory()
            #endif
            let created = AppDataStores(
                dataDirectory: dataBase.appendingPathComponent("Hummingbird", isDirectory: true),
                cachesDirectory: LiveData.cachesDirectory().appendingPathComponent("Hummingbird", isDirectory: true),
                preferences: .standard,
                credentialStore: KeychainCredentialStore.shared(
                    serviceNamespace: credentialServiceNamespace, preferences: .standard
                )
            )
            stores[key] = created
            return created
        }
    }

    /// The store, when it is the platform keychain, for storage-mode decisions.
    public var keychain: KeychainCredentialStore? { credentialStore as? KeychainCredentialStore }

    /// Makes this process's credential store the one an explicit unlock covers.
    public func registerCredentialVault() {
        CredentialVaultManager.shared.register(credentialStore)
    }
}
