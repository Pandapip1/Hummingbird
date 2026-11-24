import Crypto
import Foundation

// The synced data cache: plugin results (feeds, channel and video metadata,
// subscription-poll results; never media) kept so one device's refresh
// serves the others. Unlike the data journal it is non-authoritative and
// lossy: entries may be dropped at any time, a damaged store is discarded,
// and nothing is ever deleted on another device. It is confidential all the
// same, because together its entries say what the user looked at: encrypted
// at rest per profile, synced only end to end between trusted devices, and
// its identities never appear in logs.

/// What a cache entry is about: its kind (`video`, `channel`, `playlist`…),
/// the source (plugin) that produced it, and the source's canonical URL for
/// it. Logged or interpolated, it prints only its kind: what the user looked
/// at never reaches a log by accident.
public struct CacheEntityKey: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: String
    public let source: String
    public let url: String

    public init(kind: String, source: String, url: String) {
        self.kind = kind
        self.source = source
        self.url = url
    }

    public var description: String { "CacheEntityKey(\(kind), <redacted>)" }
    public var debugDescription: String { description }
}

/// A list of entities: a channel's videos, a feed page, search results, one
/// subscription poll. Holds references, never copies. Prints redacted.
public struct CacheListKey: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: String
    public let source: String
    public let url: String

    public init(kind: String, source: String, url: String) {
        self.kind = kind
        self.source = source
        self.url = url
    }

    public var description: String { "CacheListKey(\(kind), <redacted>)" }
    public var debugDescription: String { description }
}

/// Everything about how a result was fetched that can change it. Two devices
/// can legitimately hold different values for one entity: signed in or not,
/// another plugin version or settings, another region, an A/B test.
public struct CacheFetchContext: Hashable, Codable, Sendable {
    /// The plugin's version.
    public var sourceVersion: String
    /// A digest of the setting values that affect results (the app decides
    /// which, and computes it); empty when none do.
    public var settings: String
    /// Nil when fetched anonymously; otherwise an identifier of the signed-in
    /// account. It is only ever stored or sent as a hash keyed with the
    /// current cache epoch, never as itself.
    public var account: String?
    /// Locale and region, e.g. `en-GB`.
    public var locale: String
    /// What a viewer must be allowed to see this: `members-only`,
    /// `age-restricted`… Empty for public results.
    public var elevation: Set<String>

    public init(sourceVersion: String, settings: String = "", account: String? = nil,
                locale: String, elevation: Set<String> = []) {
        self.sourceVersion = sourceVersion
        self.settings = settings
        self.account = account
        self.locale = locale
        self.elevation = elevation
    }

    /// The context as stored and synced: the account as a keyed hash.
    func stored(in epoch: CacheEpoch) -> StoredContext {
        StoredContext(sourceVersion: sourceVersion, settings: settings,
                      accountHash: account.map(epoch.accountHash), locale: locale, elevation: elevation)
    }
}

/// A fetch context as the cache keeps and sends it: the account only as a
/// hash keyed with the epoch it was written in.
struct StoredContext: Hashable, Codable, Sendable {
    var sourceVersion: String
    var settings: String
    var accountHash: String?
    var locale: String
    var elevation: Set<String>

    /// Entries are kept apart per class: one never replaces another.
    var contextClass: CacheContextClass {
        var hasher = SHA256()
        for part in [sourceVersion, settings, accountHash ?? "", locale] + elevation.sorted() {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return CacheContextClass(raw: hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined())
    }
}

/// Identifies one fetch context (`StoredContext.contextClass`).
public struct CacheContextClass: Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: String
    public var description: String { "CacheContextClass(\(raw.prefix(6)))" }
}

/// What this device, for this profile, is now: per source, the context it
/// would fetch with, and the elevations it is allowed.
public struct CacheViewer: Sendable {
    public var contexts: [String: CacheFetchContext]
    /// Elevations this profile may see (an age-gated profile lacks
    /// `age-restricted`; a device not signed in lacks `members-only`).
    public var allowedElevation: Set<String>

    public init(contexts: [String: CacheFetchContext], allowedElevation: Set<String> = []) {
        self.contexts = contexts
        self.allowedElevation = allowedElevation
    }

    /// How a stored context serves this viewer for `source`: exactly
    /// (`fresh`), as a placeholder until a local refresh (`placeholder`), or
    /// not at all (nil).
    /// `epoch` is the one `stored` was written in: the viewer's account is
    /// hashed with it to compare.
    func match(_ stored: StoredContext, source: String, epoch: CacheEpoch) -> CacheFit? {
        guard stored.elevation.isSubset(of: allowedElevation) else { return nil }
        guard let own = contexts[source]?.stored(in: epoch) else { return nil }
        // Signed-in results are only for the same account: they may hold
        // what an anonymous viewer, or another account, can't see.
        if let account = stored.accountHash, account != own.accountHash { return nil }
        // An elevated result needs this device to fetch with that elevation too.
        guard stored.elevation.isSubset(of: own.elevation) else { return nil }
        return stored == own ? .fresh : .placeholder
    }
}

/// How well a cached value fits the viewer.
public enum CacheFit: Sendable, Equatable, Comparable {
    /// From another context (anonymous for a signed-in viewer, another
    /// plugin version, settings or region): show it, then refetch.
    case placeholder
    /// Fetched in exactly the viewer's context.
    case fresh
}

/// Where a stored value came from.
enum CacheOrigin: String, Codable, Sendable {
    /// This device fetched it.
    case local
    /// A trusted device sent it.
    case remote
}

/// A cached entity, as a reader gets it.
public struct CachedEntity: Sendable, Equatable {
    public let key: CacheEntityKey
    /// The app's compact encoding of the entity, without its large fields.
    public let payload: Data
    /// Large fields (descriptions, chapter lists), stored once however many
    /// entities share them.
    public let fields: [String: Data]
    public let fetchedAt: Date
    public let fit: CacheFit
}

/// A cached list, as a reader gets it: its entities in order, with whether
/// any were missing (evicted, or not visible here).
public struct CachedList: Sendable, Equatable {
    public let key: CacheListKey
    public let entities: [CachedEntity]
    /// Some referenced entities are gone or not visible here: refetch.
    public let isPartial: Bool
    public let fetchedAt: Date
    public let fit: CacheFit
}
