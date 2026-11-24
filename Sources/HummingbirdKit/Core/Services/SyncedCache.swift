import ATAppSync
import Crypto
import Foundation
import os
import PlatformSupport

/// Each profile's synced data cache (ATAppSync's `CacheJournal`), one per
/// profile in the process however many windows show it. It lives in a
/// `KeptDirectory` (with the app's data, out of backups, never in Caches,
/// which the system empties when storage runs low) and is served to
/// trusted devices over the local network. Never readable by plugins: only Hummingbird's services use it,
/// and a plugin only ever sees its own fresh results.
@MainActor
enum SyncedCache {
    static let budgetKey = "syncedCacheBudgetMegabytes"
    static let defaultBudgetMegabytes = 256
    static let budgetChoices = [64, 128, 256, 512, 1_024]

    private static var opened: [String: CacheJournal] = [:]

    /// The profile's cache; nil without an instance identity (it is keyed
    /// to the trusted set, which needs one).
    static func shared(stores: AppDataStores, profileID: UUID, peerService: AppSyncPeerService?) -> CacheJournal? {
        guard let peerService else { return nil }
        let key = "\(ObjectIdentifier(stores.storage))|\(profileID.uuidString)"
        if let cache = opened[key] { return cache }
        let megabytes = stores.defaults.object(forKey: budgetKey) as? Int ?? defaultBudgetMegabytes
        let profileFolder = profileID.uuidString.lowercased()
        let kept = KeptDirectory(named: "SyncedCache/" + profileFolder, inDataDirectory: stores.dataDirectory)
        moveFromCaches(stores.cachesDirectory.appendingPathComponent("SyncedCache", isDirectory: true)
            .appendingPathComponent(profileFolder, isDirectory: true), to: kept)
        let cache = CacheJournal(
            directory: kept,
            profileID: profileID, instance: peerService.identity.publicIdentity.stableID,
            credentialStore: stores.credentialStore, availability: stores.storage.protectedData,
            configuration: .init(budget: megabytes * 1_024 * 1_024)
        )
        peerService.attach(cache: cache)
        opened[key] = cache
        return cache
    }

    /// Builds before this one kept the cache in Caches: its files are moved
    /// (a rename on the same volume), never rebuilt. Files already in the
    /// new place win; the old folder goes once it is empty.
    static func moveFromCaches(_ old: URL, to kept: KeptDirectory) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: old.path) else { return }
        var moved = 0
        for name in names {
            let target = kept.url.appendingPathComponent(name)
            guard !files.fileExists(atPath: target.path) else { continue }
            do {
                try files.moveItem(at: old.appendingPathComponent(name), to: target)
                moved += 1
            } catch {
                Logger.background.error("synced_cache_move_failed error=\(String(describing: error), privacy: .public)")
            }
        }
        if (try? files.contentsOfDirectory(atPath: old.path).isEmpty) == true { try? files.removeItem(at: old) }
        Logger.background.notice("synced_cache_moved files=\(moved)")
    }

    /// The context a plugin's results are fetched in, or nil when they
    /// mustn't be shared: while signed in to the plugin, this device can't
    /// tell which account a result belongs to, so it neither shares nor
    /// uses shared results for that plugin.
    static func context(for plugin: InstalledPlugin, signedIn: Bool) -> CacheFetchContext? {
        guard !signedIn else { return nil }
        var hasher = SHA256()
        for (name, value) in plugin.settings.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("\(name)=\(value)\u{0}".utf8))
        }
        let settings = plugin.settings.isEmpty ? "" : hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return CacheFetchContext(sourceVersion: String(plugin.config.version), settings: settings,
                                 locale: Locale.current.identifier)
    }
}
