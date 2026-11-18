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
    /// pairing inboxes (`peer-messages/`) and the permission record
    /// (`permissions/`).
    public let dataDirectory: URL
    /// Disposable data: the media cache (`Media-v1/`, `UMP-v2/`) and MetricKit
    /// reports (`MetricKit/`).
    public let cachesDirectory: URL
    /// Device-local settings that are not synced.
    public let preferences: PreferencesDomain
    /// Plugin sign-ins, atproto sessions and AppSync instance identities.
    public let credentialStore: any CredentialStore

    let storage: Storage
    /// Serves generated media to the player, caching it in `cachesDirectory`.
    let mediaProxy: PluginMediaProxy
    /// Every downloaded on-demand track (`Media-v1/` in `cachesDirectory`),
    /// with the generated-media cache counted toward the same limit.
    let mediaCache: MediaCache
    /// Serves `mediaCache` to the player over loopback HTTP.
    let mediaServer = LocalMediaServer()
    /// Every VOD download; they outlive the players that started them.
    let mediaDownloads: MediaDownloads
    /// Optional transcoding of finished downloads (Quality setting).
    let transcoding: TranscodeStage
    /// Whether work that can wait should wait (saving energy, hot device).
    let backgroundWork: BackgroundWorkPolicy

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
        let generatedCache = UMPMediaCache(directory: cachesDirectory)
        mediaProxy = PluginMediaProxy(cache: generatedCache)
        let limitGigabytes = preferences.defaults.object(forKey: PlaybackPreferenceKey.mediaCacheLimitGigabytes) as? Int
        mediaCache = MediaCache(directory: cachesDirectory,
                                limitBytes: MediaCache.bytes(gigabytes: limitGigabytes ?? MediaCache.defaultLimitGigabytes),
                                sharing: [generatedCache])
        mediaDownloads = MediaDownloads(cache: mediaCache)
        let policy = BackgroundWorkPolicy()
        backgroundWork = policy
        transcoding = TranscodeStage(cache: mediaCache,
                                     scratch: cachesDirectory.appendingPathComponent("Transcode", isDirectory: true),
                                     policy: policy)
        // Downloads nobody watches pause while energy is saved.
        let downloads = mediaDownloads
        Task { await downloads.follow(policy) }
    }

    var defaults: UserDefaults { preferences.defaults }

    /// Holds the local-profile registry, instance inboxes and trust facts.
    var appSyncDirectory: URL { dataDirectory }
    var profileSyncDirectory: URL { dataDirectory.appendingPathComponent("profile-sync", isDirectory: true) }
    var peerMessagesDirectory: URL { dataDirectory.appendingPathComponent("peer-messages", isDirectory: true) }
    var permissionsDirectory: URL { dataDirectory.appendingPathComponent("permissions", isDirectory: true) }

    /// Waits for every pending write to `storage.sqlite3`.
    public func flush() async { await storage.flush() }

    /// Blocks until pending writes are done; only for quitting.
    func flushBeforeTermination() { storage.flushBeforeTermination() }

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
            #if DEBUG
            if let root = ProcessInfo.processInfo.environment[debugDataRootVariable], !root.isEmpty {
                // A relative root is inside the app's own temporary directory,
                // which UI tests use so isolation works on devices too.
                let rootURL = root.hasPrefix("/")
                    ? URL(fileURLWithPath: root, isDirectory: true)
                    : FileManager.default.temporaryDirectory.appendingPathComponent(root, isDirectory: true)
                let created = debugIsolated(root: rootURL)
                stores[key] = created
                return created
            }
            #else
            // Only debug builds can isolate their data. Whoever asked for an
            // isolated launch (a UI test, a profiling run) must never get the
            // real data instead, so a release build refuses to start.
            if ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_DATA_ROOT"] != nil {
                fatalError("""
                    HUMMINGBIRD_DEBUG_DATA_ROOT is set, but this is a release build, which only uses the \
                    real data. Run a debug build to isolate the app's data.
                    """)
            }
            #endif
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

    #if DEBUG
    /// Debug builds only: launch with `HUMMINGBIRD_DEBUG_DATA_ROOT=<directory>`
    /// to keep everything under that directory, with a UserDefaults suite of
    /// its own and an in-memory credential store, so profiling or trying out
    /// a build never touches the real profile, library or keychain.
    public static let debugDataRootVariable = "HUMMINGBIRD_DEBUG_DATA_ROOT"

    private static func debugIsolated(root: URL) -> AppDataStores {
        AppDataStores(
            dataDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            preferences: .suite(root.appendingPathComponent("preferences", isDirectory: false).path),
            credentialStore: EphemeralCredentialStore()
        )
    }
    #endif

    /// The store, when it is the platform keychain, for storage-mode decisions.
    public var keychain: KeychainCredentialStore? { credentialStore as? KeychainCredentialStore }

    /// Makes this process's credential store the one an explicit unlock covers.
    public func registerCredentialVault() {
        CredentialVaultManager.shared.register(credentialStore)
    }
}

#if DEBUG
/// Credentials kept in memory for the life of the process, for debug launches
/// isolated with `HUMMINGBIRD_DEBUG_DATA_ROOT`.
final class EphemeralCredentialStore: CredentialStore {
    private let values = Mutex<[String: SecureBytes]>([:])

    func load(account: String) -> SecureBytes? { values.withLock { $0[account] } }
    func save(_ secret: SecureBytes, account: String) { values.withLock { $0[account] = secret } }
    func delete(account: String) { values.withLock { $0[account] = nil } }
}
#endif
