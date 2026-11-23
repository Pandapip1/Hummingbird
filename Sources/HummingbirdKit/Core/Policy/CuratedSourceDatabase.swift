import Crypto
import Foundation
import os
import Synchronization

/// One reviewed source: where it comes from, the author key it must be
/// signed with, and the rating assigned to it.
struct CuratedSourceEntry: Codable, Hashable, Sendable, Identifiable {
    var pluginID: String
    var name: String
    var summary: String = ""
    /// The plugin's config URL, which installing from the catalog uses.
    var configURL: String = ""
    /// The script signing key the reviewed plugin is signed with (base64
    /// SPKI, as in a Grayjay config's `scriptPublicKey`). A config with the
    /// same id but another key is not this source: it counts as unlisted.
    var publicKey: String
    var category: SourceCategory
    /// The rating assigned to this plugin; nil uses the category's default.
    var minimumAge: Int?
    /// Settings that raise the rating above `minimumAge` (the rating with
    /// every one of them at its safe value).
    var settingRatings: [SettingRating] = []

    var id: String { pluginID }

    var classification: SourceClassification {
        SourceClassification(pluginID: pluginID, isCurated: true, category: category,
                             explicitMinimumAge: minimumAge, settingRatings: settingRatings)
    }
}

/// The reviewed list as it ships and as signed updates deliver it.
struct CuratedSourceList: Codable, Hashable, Sendable {
    /// The file format; this app reads format 1.
    var format: Int
    /// Rises with every published list; an update must be newer.
    var version: Int
    var generatedAt: String
    var entries: [CuratedSourceEntry]

    static let supportedFormat = 1
}

/// The curated plugin database. The bundled list (`CuratedSources.json`,
/// generated from the official Grayjay configs with each key pinned and a
/// rating assigned per plugin) is replaced only by a newer list whose
/// signature verifies (`applyUpdate`).
///
/// Community listings such as grayjay-sources are curation input only: an
/// entry gets here by review, never by being listed elsewhere.
final class CuratedSourceDatabase: SourceClassifier {
    private let current: Mutex<CuratedSourceList>

    /// The app's database. Starts from the bundled list.
    static let shared = CuratedSourceDatabase()

    init(list: CuratedSourceList = CuratedSourceDatabase.bundled) {
        current = Mutex(list)
    }

    var list: CuratedSourceList { current.withLock { $0 } }
    var entries: [CuratedSourceEntry] { list.entries }
    var reviewedEntries: [CuratedSourceEntry] { entries }

    func entry(for pluginID: String) -> CuratedSourceEntry? {
        current.withLock { list in list.entries.first { $0.pluginID == pluginID } }
    }

    func classification(for config: PluginConfig) -> SourceClassification {
        guard let entry = entry(for: config.id), entry.publicKey == config.scriptPublicKey else {
            return .unlisted(config.id)
        }
        return entry.classification
    }

    func reviewedName(ofLookalike config: PluginConfig) -> String? {
        guard let entry = entry(for: config.id), entry.publicKey != config.scriptPublicKey else { return nil }
        return entry.name
    }

    /// The list that ships with the app.
    static let bundled: CuratedSourceList = {
        guard let url = Bundle.module.url(forResource: "CuratedSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(CuratedSourceList.self, from: data) else {
            // A packaging error: nothing is curated, so every source is
            // treated as unlisted (18+). Restrictive, never permissive.
            Logger.policy.fault("curated_sources_bundle_missing")
            return CuratedSourceList(format: 1, version: 0, generatedAt: "", entries: [])
        }
        return list
    }()

    enum UpdateError: Error, Equatable {
        case badSignature
        case unreadable
        case unsupportedFormat(Int)
        case notNewer(current: Int, offered: Int)
    }

    /// Adopts `body` (a `CuratedSourceList` as JSON) if `signature` (raw
    /// Ed25519 over exactly those bytes) verifies under `publicKey`, the
    /// format is understood, and the version is newer than the current one.
    @discardableResult
    func applyUpdate(body: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) throws -> CuratedSourceList {
        guard publicKey.isValidSignature(signature, for: body) else { throw UpdateError.badSignature }
        guard let list = try? JSONDecoder().decode(CuratedSourceList.self, from: body) else {
            throw UpdateError.unreadable
        }
        guard list.format == CuratedSourceList.supportedFormat else { throw UpdateError.unsupportedFormat(list.format) }
        try current.withLock { stored in
            guard list.version > stored.version else {
                throw UpdateError.notNewer(current: stored.version, offered: list.version)
            }
            stored = list
        }
        return list
    }
}

/// Optional signed updates of the curated list from a server. Off unless the
/// app is built with a signing key (`publicKey`): without one there is no
/// way to tell a genuine list from a forged one, so nothing is fetched.
/// Accepted updates are kept (body and signature) and verified again at each
/// launch.
struct CuratedSourceUpdater: Sendable {
    /// Where the list is published; the signature is at the same URL plus
    /// ".sig" (base64 Ed25519).
    var listURL: URL
    var publicKey: Curve25519.Signing.PublicKey
    var storage: Storage
    var storageName = "curated_sources_update"

    struct Stored: Codable, Sendable {
        let body: Data
        let signature: Data
    }

    /// The app's configuration. No key is configured yet, so updates are off.
    static let configured: (url: URL, publicKey: Curve25519.Signing.PublicKey)? = nil

    /// Re-applies the last accepted update, if it still verifies.
    func restore(into database: CuratedSourceDatabase) {
        guard let stored = storage.load(Stored.self, name: storageName) else { return }
        _ = try? database.applyUpdate(body: stored.body, signature: stored.signature, publicKey: publicKey)
    }

    /// Fetches, verifies and adopts a newer list. Errors leave the current
    /// list in place.
    func update(_ database: CuratedSourceDatabase, session: URLSession = .shared) async throws -> CuratedSourceList {
        let (body, _) = try await session.data(from: listURL)
        let (signatureText, _) = try await session.data(from: listURL.appendingPathExtension("sig"))
        guard let signature = Data(base64Encoded: String(decoding: signatureText, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) else { throw CuratedSourceDatabase.UpdateError.badSignature }
        let list = try database.applyUpdate(body: body, signature: signature, publicKey: publicKey)
        storage.save(Stored(body: body, signature: signature), name: storageName)
        return list
    }
}
