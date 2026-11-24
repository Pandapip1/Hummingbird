import Foundation

// Cache sync between a profile's trusted devices. It travels only inside
// envelopes sealed to the peer's instance key (as the data journal's LAN
// sync does), never to a relay or PDS. A reader asks for a peer's manifest
// (keys, contexts and fetch times; lists with their references), works out
// what it lacks, and fetches exactly that: every entity and blob at most
// once, never lists of embedded copies. Both legs are padded to fixed size
// steps, and run only in scheduled passes, so traffic doesn't say which
// items moved.

/// What a device holds in the current epoch.
struct CacheManifest: Codable, Sendable {
    struct Entity: Codable, Sendable {
        let key: CacheEntityKey
        let context: StoredContext
        let fetchedAt: Date
    }

    struct List: Codable, Sendable {
        let key: CacheListKey
        let context: StoredContext
        let fetchedAt: Date
    }

    let epoch: CacheEpochID
    let entities: [Entity]
    let lists: [List]
}

/// What a reader asks for.
struct CacheWant: Codable, Sendable {
    let epoch: CacheEpochID
    var entities: [CacheSlot]
    var lists: [CacheListSlot]

    var isEmpty: Bool { entities.isEmpty && lists.isEmpty }
}

/// The records asked for. Blobs are sent once each and referred to by
/// position, so no keyed blob ID leaves the device.
struct CacheTransfer: Codable, Sendable {
    struct Entity: Codable, Sendable {
        let key: CacheEntityKey
        let context: StoredContext
        let payload: Data
        let fields: [String: Int]
        let fetchedAt: Date
    }

    struct List: Codable, Sendable {
        let key: CacheListKey
        let context: StoredContext
        let references: [CacheEntityKey]
        let fetchedAt: Date
    }

    let epoch: CacheEpochID
    var entities: [Entity]
    var lists: [List]
    var blobs: [Data]
}

/// One cache-sync request, sealed to the peer.
struct CacheSyncRequest: Codable, Sendable {
    enum Step: Codable, Sendable {
        case manifest
        case fetch(CacheWant)
    }

    let nonce: UUID
    let appID: AppSyncAppID
    let epoch: CacheEpochID?
    let step: Step
    /// Fills the encoded request up to a size step.
    var padding: String = ""

    mutating func pad(step: Int = CacheSyncPadding.step) throws {
        padding = ""
        let size = try JSONEncoder().encode(self).count
        padding = String(repeating: "0", count: CacheSyncPadding.paddedSize(size, step: step) - size)
    }
}

/// A peer's answer, sealed to the reader. When the epochs differ it carries
/// only the peer's epoch keys (if the reader is one of its members); the
/// reader adopts them if they win, and asks again.
struct CacheSyncResponse: Codable, Sendable {
    let nonce: UUID
    var offer: CacheEpochOffer?
    var manifest: CacheManifest?
    var transfer: CacheTransfer?
    /// Fills the encoded response up to a size step.
    var padding: String = ""

    /// Pads the encoded size up to the next multiple of `step` bytes.
    mutating func pad(step: Int = CacheSyncPadding.step) throws {
        padding = ""
        let size = try JSONEncoder().encode(self).count
        let target = CacheSyncPadding.paddedSize(size, step: step)
        padding = String(repeating: "0", count: target - size)
    }
}

enum CacheSyncPadding {
    static let step = 16 * 1_024

    static func paddedSize(_ size: Int, step: Int) -> Int {
        max(step, (size + step - 1) / step * step)
    }
}

extension CacheJournal {
    /// Answers a peer's sealed request. `requester` is already known to be
    /// trusted.
    func respond(to request: CacheSyncRequest, from requester: AppSyncPeerID) throws -> CacheSyncResponse {
        var response = CacheSyncResponse(nonce: request.nonce)
        guard let current = epoch else { throw CacheError.unavailable }
        if request.epoch != current {
            // Hand over this epoch's keys if the reader is a member; if the
            // reader's epoch wins, it ignores them and this device adopts
            // the reader's at its own next pull.
            response.offer = offer(to: requester)
        } else {
            switch request.step {
            case .manifest: response.manifest = manifest()
            case .fetch(let want): response.transfer = try transfer(for: want)
            }
        }
        try response.pad()
        return response
    }
}
