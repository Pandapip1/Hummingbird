import Crypto
import ATProtoKit
import Foundation
import CredentialStorage
import NIOCore
import PlatformSupport
import NIOHTTP1
import NIOPosix
import os

/// Semantic application-facing names. Instance registration and inbox records
/// are wire details; applications communicate with peers using sealed messages.
public typealias AppSyncPeer = InstancePublicIdentity
public typealias AppSyncPeerIdentity = InstanceIdentity
public typealias AppSyncPeerIdentityStore = InstanceIdentityStore
public typealias AppSyncSealedMessage = InstanceInboxEnvelope
public typealias AppSyncMessageStore = InstanceInbox
public typealias AppSyncPeerService = InstanceMessagingService
public typealias AppSyncPeerError = InstanceMessagingError

public protocol AppSyncCredentialStore: CredentialDataVault {}

public struct InstancePublicIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public let signingKey: Data
    public let encryptionKey: Data
    public var stableID: AppSyncPeerID { .init(signingKey: signingKey) }

    public init(id: UUID, signingKey: Data, encryptionKey: Data) {
        self.id = id
        self.signingKey = signingKey
        self.encryptionKey = encryptionKey
    }

    fileprivate var signingPublicKey: P256.Signing.PublicKey {
        get throws { try P256.Signing.PublicKey(rawRepresentation: signingKey) }
    }

    fileprivate var encryptionPublicKey: P256.KeyAgreement.PublicKey {
        get throws { try P256.KeyAgreement.PublicKey(rawRepresentation: encryptionKey) }
    }

    public func verificationEmoji(sessionSecret: Data) -> String {
        let material = signingKey + encryptionKey + sessionSecret
        return VerificationEmoji.render(Array(SHA256.hash(data: material)))
    }

    func verify(signature: Data, domain: String, payload: Data) throws {
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        var transcript = Data(domain.utf8); transcript.append(0); transcript.append(payload)
        guard try signingPublicKey.isValidSignature(parsed, for: transcript) else {
            throw AppSyncTrustError.invalidSignature
        }
    }
}

public struct InstanceIdentity: Sendable {
    public let publicIdentity: InstancePublicIdentity
    fileprivate let signingKey: P256.Signing.PrivateKey
    fileprivate let encryptionKey: P256.KeyAgreement.PrivateKey

    /// The vault form of an identity. Its key fields are ordinary `Data`
    /// because JSON needs it; `wipe()` zeroes them once they have been used.
    fileprivate struct Stored: Codable {
        let id: UUID
        var signingKey: Data
        var encryptionKey: Data

        mutating func wipe() {
            signingKey.resetBytes(in: signingKey.startIndex..<signingKey.endIndex)
            encryptionKey.resetBytes(in: encryptionKey.startIndex..<encryptionKey.endIndex)
        }
    }

    private init(publicIdentity: InstancePublicIdentity, signingKey: P256.Signing.PrivateKey,
                 encryptionKey: P256.KeyAgreement.PrivateKey) {
        self.publicIdentity = publicIdentity
        self.signingKey = signingKey
        self.encryptionKey = encryptionKey
    }

    public static func generate() -> Self {
        let signing = P256.Signing.PrivateKey()
        let encryption = P256.KeyAgreement.PrivateKey()
        return Self(
            publicIdentity: .init(
                id: UUID(), signingKey: signing.publicKey.rawRepresentation,
                encryptionKey: encryption.publicKey.rawRepresentation
            ),
            signingKey: signing, encryptionKey: encryption
        )
    }

    fileprivate init(stored: Stored) throws {
        let signing = try P256.Signing.PrivateKey(rawRepresentation: stored.signingKey)
        let encryption = try P256.KeyAgreement.PrivateKey(rawRepresentation: stored.encryptionKey)
        self.init(
            publicIdentity: .init(
                id: stored.id, signingKey: signing.publicKey.rawRepresentation,
                encryptionKey: encryption.publicKey.rawRepresentation
            ),
            signingKey: signing, encryptionKey: encryption
        )
    }

    fileprivate var stored: Stored {
        .init(id: publicIdentity.id, signingKey: signingKey.rawRepresentation,
              encryptionKey: encryptionKey.rawRepresentation)
    }

    public func journalSigner() throws -> JournalEventSigner {
        try .init(instanceID: publicIdentity.id,
                  privateKeyRepresentation: signingKey.rawRepresentation)
    }

    public func mutationSigner() throws -> AppSyncMutationSigner { try journalSigner() }

    func sign(domain: String, payload: Data) throws -> Data {
        var transcript = Data(domain.utf8); transcript.append(0); transcript.append(payload)
        return try signingKey.signature(for: transcript).derRepresentation
    }

    public func trustFact(with peer: AppSyncPeer,
                          timestamp: HybridLogicalTimestamp) throws -> AppSyncTrustFact {
        try AppSyncTrustFact(
            timestamp: timestamp, kind: .trust, issuer: publicIdentity, subject: peer
        ).signed(by: self)
    }
}

public final class InstanceIdentityStore: @unchecked Sendable {
    private static let legacyAccount = "com.eightybps.appsync.instance-identity.v1"
    private let credentialStore: any AppSyncCredentialStore
    private let account: String
    private let migrateLegacyIdentity: Bool
    private let lock = NSLock()
    private var cached: InstanceIdentity?

    public init(credentialStore: any AppSyncCredentialStore, profileID: UUID? = nil,
                migrateLegacyIdentity: Bool = false) {
        self.credentialStore = credentialStore
        account = profileID.map {
            "com.eightybps.appsync.profile.\($0.uuidString.lowercased()).instance-identity.v1"
        } ?? Self.legacyAccount
        self.migrateLegacyIdentity = migrateLegacyIdentity
    }

    public func identity() throws -> InstanceIdentity {
        try lock.withLock {
            if let cached { return cached }
            let profileSecret = try credentialStore.load(account: account)
            let storedSecret = try profileSecret
                ?? (migrateLegacyIdentity ? credentialStore.load(account: Self.legacyAccount) : nil)
            if let secret = storedSecret,
               var stored = try? secret.decodeJSON(InstanceIdentity.Stored.self) {
                defer { stored.wipe() }
                let identity = try InstanceIdentity(stored: stored)
                if profileSecret == nil {
                    try credentialStore.save(secret, account: account)
                }
                cached = identity
                return identity
            }
            let identity = InstanceIdentity.generate()
            var stored = identity.stored
            defer { stored.wipe() }
            let secret = try SecureBytes(jsonEncoding: stored)
            try credentialStore.save(secret, account: account)
            guard try credentialStore.load(account: account) == secret else {
                throw InstanceMessagingError.credentialNotPersisted
            }
            cached = identity
            return identity
        }
    }
}

public struct InstanceInboxEnvelope: Codable, Hashable, Sendable, Identifiable {
    static let version = 1
    public let id: UUID
    public let createdAt: Date
    public let appID: AppSyncAppID
    public let sender: InstancePublicIdentity
    public let recipientID: UUID
    public let ephemeralKey: Data
    public let ciphertext: Data
    public let signature: Data

    public init(id: UUID, createdAt: Date, appID: AppSyncAppID, sender: InstancePublicIdentity,
                recipientID: UUID, ephemeralKey: Data, ciphertext: Data, signature: Data) {
        self.id = id
        self.createdAt = createdAt
        self.appID = appID
        self.sender = sender
        self.recipientID = recipientID
        self.ephemeralKey = ephemeralKey
        self.ciphertext = ciphertext
        self.signature = signature
    }

    private struct Unsigned: Codable {
        let version: Int
        let id: UUID
        let createdAt: Date
        let appID: AppSyncAppID
        let sender: InstancePublicIdentity
        let recipientID: UUID
        let ephemeralKey: Data
        let ciphertext: Data
    }

    public static func seal<Payload: Encodable & Sendable>(
        _ payload: Payload, appID: AppSyncAppID, from sender: InstanceIdentity,
        to recipient: InstancePublicIdentity,
        id: UUID = UUID(), createdAt: Date = Date()
    ) throws -> Self {
        let createdAt = Date(
            timeIntervalSince1970: floor(createdAt.timeIntervalSince1970 * 1_000) / 1_000
        )
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.encryptionPublicKey)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(id.uuidString.lowercased().utf8),
            sharedInfo: Data("com.eightybps.appsync.inbox.v1".utf8), outputByteCount: 32
        )
        let plaintext = try JSONEncoder.appSyncInbox.encode(payload)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: key).combined else {
            throw InstanceMessagingError.encryptionFailed
        }
        let unsigned = Unsigned(
            version: version, id: id, createdAt: createdAt, appID: appID, sender: sender.publicIdentity,
            recipientID: recipient.id, ephemeralKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: ciphertext
        )
        let signature = try sender.signingKey.signature(
            for: JSONEncoder.appSyncInbox.encode(unsigned)
        ).derRepresentation
        return Self(
            id: id, createdAt: createdAt, appID: appID, sender: sender.publicIdentity, recipientID: recipient.id,
            ephemeralKey: ephemeral.publicKey.rawRepresentation, ciphertext: ciphertext,
            signature: signature
        )
    }

    public func verify() throws {
        let unsigned = Unsigned(
            version: Self.version, id: id, createdAt: createdAt, appID: appID, sender: sender,
            recipientID: recipientID, ephemeralKey: ephemeralKey, ciphertext: ciphertext
        )
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard try sender.signingPublicKey.isValidSignature(
            signature, for: JSONEncoder.appSyncInbox.encode(unsigned)
        ) else { throw InstanceMessagingError.invalidSignature }
    }

    public func open<Payload: Decodable & Sendable>(as: Payload.Type, using recipient: InstanceIdentity) throws -> Payload {
        guard recipientID == recipient.publicIdentity.id else { throw InstanceMessagingError.wrongRecipient }
        try verify()
        let ephemeral = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralKey)
        let shared = try recipient.encryptionKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(id.uuidString.lowercased().utf8),
            sharedInfo: Data("com.eightybps.appsync.inbox.v1".utf8), outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try JSONDecoder.appSyncInbox.decode(Payload.self, from: AES.GCM.open(box, using: key))
    }
}

public final class InstanceInbox: @unchecked Sendable {
    private struct Snapshot: Codable { var envelopes: [InstanceInboxEnvelope] }
    private let identity: InstanceIdentity
    private let fileURL: URL?
    private let lock = NSLock()
    private var envelopes: [UUID: InstanceInboxEnvelope]

    public init(identity: InstanceIdentity, fileURL: URL? = nil) throws {
        self.identity = identity
        self.fileURL = fileURL
        // A file that can't be read now throws (never taken for an empty
        // inbox and written over); one that doesn't decode is kept aside.
        let data = try fileURL.flatMap { try AtomicFile.contents(of: $0) }
        let stored = data.flatMap { try? JSONDecoder.appSyncInbox.decode(Snapshot.self, from: $0) }
        if let data, stored == nil, let fileURL { try AtRestQuarantine.keep(data, label: "inbox", near: fileURL) }
        envelopes = Dictionary(uniqueKeysWithValues: (stored?.envelopes ?? []).map { ($0.id, $0) })
    }

    var recipient: InstancePublicIdentity { identity.publicIdentity }

    /// Remote callers may only append. Existing IDs are immutable and a
    /// mismatched replay is rejected rather than replacing local data.
    public func appendRemote(_ envelope: InstanceInboxEnvelope) throws {
        guard envelope.recipientID == identity.publicIdentity.id else {
            throw InstanceMessagingError.wrongRecipient
        }
        try envelope.verify()
        try lock.withLock {
            if let existing = envelopes[envelope.id] {
                guard existing == envelope else { throw InstanceMessagingError.conflictingReplay }
                return
            }
            var candidate = envelopes
            candidate[envelope.id] = envelope
            try persist(candidate)
            envelopes = candidate
        }
    }

    public func pending() -> [InstanceInboxEnvelope] {
        lock.withLock { envelopes.values.sorted { $0.createdAt < $1.createdAt } }
    }

    /// Only code holding this local inbox object can delete an accepted item.
    public func deleteLocal(id: UUID) throws {
        try lock.withLock {
            guard envelopes[id] != nil else { return }
            var candidate = envelopes
            candidate[id] = nil
            try persist(candidate)
            envelopes = candidate
        }
    }

    public func open<Payload: Decodable & Sendable>(_ envelope: InstanceInboxEnvelope, as: Payload.Type) throws -> Payload {
        try envelope.open(as: Payload.self, using: identity)
    }

    private func persist(_ value: [UUID: InstanceInboxEnvelope]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let snapshot = Snapshot(envelopes: value.values.sorted { $0.createdAt < $1.createdAt })
        try AtomicFile.write(JSONEncoder.appSyncInbox.encode(snapshot), to: fileURL)
    }
}

public final class InstanceInboxLANServer: @unchecked Sendable {
    private let identity: InstanceIdentity
    private let inbox: InstanceInbox
    private let trustStore: AppSyncTrustStore
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private(set) var endpoint: URL?
    private var registration: AppSyncInstanceRegistration?
    private var journal: OfflineMutationJournal?
    private var verifier: AppSyncPeerVerifier?
    private var cache: CacheJournal?

    public init(identity: InstanceIdentity, inbox: InstanceInbox, trustStore: AppSyncTrustStore) {
        self.identity = identity
        self.inbox = inbox
        self.trustStore = trustStore
    }

    public func publish(_ registration: AppSyncInstanceRegistration) {
        lock.withLock { self.registration = registration }
    }

    public func attach(journal: OfflineMutationJournal) {
        lock.withLock { self.journal = journal }
    }

    /// Serves the profile's synced cache to trusted peers.
    public func attach(cache: CacheJournal) {
        lock.withLock { self.cache = cache }
    }

    func attach(verifier: AppSyncPeerVerifier) {
        lock.withLock { self.verifier = verifier }
    }

    /// The registration this server currently publishes.
    var publishedRegistration: AppSyncInstanceRegistration? {
        lock.withLock { registration }
    }

    deinit {
        stop()
        group.shutdownGracefully { _ in }
    }

    public func start(appIDs: Set<AppSyncAppID>) async throws -> URL {
        if let endpoint = lock.withLock({ endpoint }) { return endpoint }
        let inbox = self.inbox
        let trustStore = self.trustStore
        let owner = WeakLANServer(self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(InboxAppendHTTPHandler { head, data in
                        guard let self = owner.value else {
                            return .init(status: .serviceUnavailable)
                        }
                        if head.method == .GET, head.uri == "/appsync/v1/registration" {
                            guard let registration = self.lock.withLock({ self.registration }),
                                  let body = try? JSONEncoder().encode(registration) else {
                                return .init(status: .serviceUnavailable)
                            }
                            return .init(status: .ok, body: body, contentType: "application/json")
                        }
                        if head.method == .POST, head.uri == AppSyncPeerVerifier.route {
                            guard let verifier = self.lock.withLock({ self.verifier }) else {
                                return .init(status: .serviceUnavailable)
                            }
                            let reply = verifier.handle(data)
                            return .init(
                                status: HTTPResponseStatus(statusCode: reply.status), body: reply.body,
                                contentType: reply.body.isEmpty ? nil : "application/json"
                            )
                        }
                        if head.method == .POST, head.uri == "/appsync/v1/sync" {
                            return self.syncResponse(data, appIDs: appIDs)
                        }
                        if head.method == .POST, head.uri == CacheSyncRoute.path {
                            return self.cacheResponse(data, appIDs: appIDs)
                        }
                        guard head.method == .POST, head.uri == "/inbox",
                              let envelope = try? JSONDecoder().decode(InstanceInboxEnvelope.self, from: data),
                              appIDs.contains(envelope.appID),
                              trustStore.trusts(envelope.sender.stableID)
                        else { return .init(status: .forbidden) }
                        do {
                            try inbox.appendRemote(envelope)
                            return .init(status: .noContent)
                        } catch { return .init(status: .badRequest) }
                    })
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        // Bind the IPv6 wildcard. Platforms that permit mapped IPv4 retain
        // dual-stack reachability, while IPv6-only LANs work without fallback.
        let channel = try await bootstrap.bind(host: "::", port: 0).get()
        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            throw InstanceMessagingError.serverUnavailable
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = ProcessInfo.processInfo.hostName
        components.port = port
        components.path = "/inbox"
        guard let endpoint = components.url else { throw InstanceMessagingError.serverUnavailable }
        lock.withLock { self.channel = channel; self.endpoint = endpoint }
        return endpoint
    }

    private func syncResponse(_ data: Data, appIDs: Set<AppSyncAppID>) -> LANHTTPResponse {
        let signposter = AppSyncDiagnostics.lanSignposter
        let signpost = signposter.beginInterval("LANServe", id: signposter.makeSignpostID(), "path=sync")
        let response = makeSyncResponse(data, appIDs: appIDs)
        signposter.endInterval("LANServe", signpost, "status=\(response.status.code)")
        if response.status != .ok {
            AppSyncDiagnostics.lan.notice("lan_sync_refused status=\(response.status.code)")
        }
        return response
    }

    /// A trusted peer's cache request, answered sealed to it. Requests
    /// from anyone else, or not sealed to this instance, are refused.
    private func cacheResponse(_ data: Data, appIDs: Set<AppSyncAppID>) -> LANHTTPResponse {
        guard let envelope = try? JSONDecoder().decode(InstanceInboxEnvelope.self, from: data),
              appIDs.contains(envelope.appID), trustStore.trusts(envelope.sender.stableID),
              let request = try? inbox.open(envelope, as: CacheSyncRequest.self),
              request.appID == envelope.appID,
              let cache = lock.withLock({ self.cache }) else { return .init(status: .forbidden) }
        do {
            let response = try cache.respond(to: request, from: envelope.sender.stableID)
            let sealed = try InstanceInboxEnvelope.seal(response, appID: request.appID, from: identity,
                                                        to: envelope.sender)
            return .init(status: .ok, body: try JSONEncoder().encode(sealed), contentType: "application/json")
        } catch {
            return .init(status: .conflict)
        }
    }

    private func makeSyncResponse(_ data: Data, appIDs: Set<AppSyncAppID>) -> LANHTTPResponse {
        guard let envelope = try? JSONDecoder().decode(InstanceInboxEnvelope.self, from: data),
              appIDs.contains(envelope.appID), trustStore.trusts(envelope.sender.stableID),
              let request = try? inbox.open(envelope, as: AppSyncLANRequest.self),
              request.appID == envelope.appID else { return .init(status: .forbidden) }
        do {
            let journal = lock.withLock { self.journal }
            // A reader that says where it got up to gets only what arrived
            // since; one that doesn't (or an older instance) gets everything.
            let delta = journal?.events(after: request.since)
            let events = delta?.events ?? []
            let batch = try events.isEmpty ? nil : journal?.signedBatch(
                type: NSID(rawValue: "com.eightybps.appsync.journal")!, mutations: events
            )
            let snapshot = AppSyncLANSnapshot(
                nonce: request.nonce, journal: batch, trustFacts: trustStore.facts(),
                cursor: delta?.cursor
            )
            let response = try InstanceInboxEnvelope.seal(
                snapshot, appID: request.appID, from: identity, to: envelope.sender
            )
            return .init(
                status: .ok, body: try JSONEncoder().encode(response),
                contentType: "application/json"
            )
        } catch { return .init(status: .internalServerError) }
    }

    public func stop() {
        let channel = lock.withLock { () -> Channel? in
            let value = self.channel
            self.channel = nil
            endpoint = nil
            return value
        }
        channel?.close(promise: nil)
    }
}

private final class WeakLANServer: @unchecked Sendable {
    weak var value: InstanceInboxLANServer?
    init(_ value: InstanceInboxLANServer) { self.value = value }
}

public struct InstanceInboxAdvertisement: Codable, Hashable, Sendable {
    public let identity: InstancePublicIdentity
    public let endpoint: URL
}

public final class InstanceMessagingService: @unchecked Sendable {
    public let profileID: UUID
    public let identity: InstanceIdentity
    public let inbox: InstanceInbox
    public let trustStore: AppSyncTrustStore
    public var peer: AppSyncPeerIdentity { identity }
    public var messageStore: AppSyncMessageStore { inbox }
    public var verificationCode: AppSyncPeerVerificationCode {
        .init(peerID: identity.publicIdentity.stableID)
    }
    private let server: InstanceInboxLANServer
    private let discovery = AppSyncLANDiscovery()
    private let verifier: AppSyncPeerVerifier
    private let trustLock = NSLock()
    private var trustClock: HybridLogicalClock

    public init(credentialStore: any AppSyncCredentialStore, storageDirectory: URL,
                profileID: UUID = UUID(), migrateLegacyIdentity: Bool = false) throws {
        self.profileID = profileID
        identity = try InstanceIdentityStore(
            credentialStore: credentialStore, profileID: profileID,
            migrateLegacyIdentity: migrateLegacyIdentity
        ).identity()
        let file = storageDirectory.appendingPathComponent("instance-inbox", isDirectory: true)
            .appendingPathComponent("\(identity.publicIdentity.id.uuidString.lowercased()).json")
        inbox = try InstanceInbox(identity: identity, fileURL: file)
        trustStore = try AppSyncTrustStore(
            observer: identity.publicIdentity,
            fileURL: storageDirectory.appendingPathComponent("peer-trust", isDirectory: true)
                .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("facts.json")
        )
        trustClock = HybridLogicalClock(deviceID: identity.publicIdentity.id)
        server = InstanceInboxLANServer(identity: identity, inbox: inbox, trustStore: trustStore)
        let server = server
        verifier = AppSyncPeerVerifier(identity: identity) { server.publishedRegistration }
        server.attach(verifier: verifier)
        verifier.setTrustHandler { [weak self] peer in _ = try self?.trust(peer) }
    }

    // MARK: Emoji verification

    /// Starts emoji verification with a reachable instance. Both instances
    /// then show the same emoji; once the user confirms on both, each trusts
    /// the other.
    public func startVerification(with registration: AppSyncInstanceRegistration) async throws -> UUID {
        try await verifier.start(with: registration)
    }

    /// The user says the emoji match.
    public func confirmVerification(_ id: UUID) async throws { try await verifier.confirm(id) }

    /// The user says the emoji differ, or gives up.
    public func cancelVerification(_ id: UUID) async { await verifier.cancel(id) }

    /// Forgets a finished verification.
    public func dismissVerification(_ id: UUID) { verifier.dismiss(id) }

    /// Verifications in progress or recently finished, started here or by
    /// another instance.
    public func verifications() -> [AppSyncPeerVerification] { verifier.verifications() }

    public func startLANServer(appIDs: Set<AppSyncAppID>) async throws -> InstanceInboxAdvertisement {
        let advertisement = InstanceInboxAdvertisement(
            identity: identity.publicIdentity, endpoint: try await server.start(appIDs: appIDs)
        )
        let registration = try registration(
            appIDs: appIDs, advertisement: advertisement
        )
        server.publish(registration)
        try await discovery.start(advertising: registration)
        return advertisement
    }

    /// Fires whenever `peers(appIDs:)` or `verifications()` may return
    /// something different: an instance appeared, changed or went away on the
    /// local network, trust changed, or a verification progressed. Each
    /// element only says "look again".
    public func changes() -> AsyncStream<Void> {
        let sources = [discovery.changes.stream(), trustStore.changes.stream(),
                       verifier.changes.stream()]
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let forwarders = sources.map { source in
                Task { for await _ in source { continuation.yield() } }
            }
            continuation.onTermination = { _ in forwarders.forEach { $0.cancel() } }
        }
    }

    /// Fires when local network privacy blocks this instance's advertising or
    /// browsing after `startLANServer` returned.
    public func localNetworkDenials() -> AsyncStream<Void> {
        discovery.policyDenials.stream()
    }

    /// Recently observed, cryptographically authenticated LAN registrations.
    /// Presence is advisory and expires quickly; trust remains an independent
    /// user decision evaluated by `AppSyncTrustStore`.
    public func discoveredRegistrations() -> [AppSyncInstanceRegistration] {
        discovery.registrations()
    }

    /// Accepts a signed registration supplied by another discovery mechanism.
    /// DNS-SD uses this same verified cache internally; applications may feed
    /// equivalent nearby transports without weakening identity validation.
    public func observeDiscoveredRegistration(
        _ registration: AppSyncInstanceRegistration
    ) throws {
        try discovery.observe(registration)
    }

    public func attach(journal: OfflineMutationJournal) { server.attach(journal: journal) }

    /// Serves `cache` to trusted peers over the local network.
    public func attach(cache: CacheJournal) { server.attach(cache: cache) }

    /// Peers with a trust relationship or a compatible registration nearby.
    /// Trusted peers that aren't reachable now are included without a
    /// registration.
    public func peers(appIDs: Set<AppSyncAppID>) -> [AppSyncPeerTrustSummary] {
        trustStore.knownPeers(among: discovery.registrations(), localAppIDs: appIDs)
    }

    @discardableResult
    public func verifyPeer(
        _ code: AppSyncPeerVerificationCode, appIDs: Set<AppSyncAppID>
    ) throws -> AppSyncPeerTrustSummary {
        // Verification needs the peer's current signed registration.
        let compatible = trustStore.peers(
            among: discovery.registrations(), localAppIDs: appIDs
        )
        guard let match = compatible.first(where: { $0.id == code.peerID }),
              let registration = match.registration else {
            throw AppSyncPeerVerificationError.peerNotFound
        }
        _ = try trust(match.peer)
        return .init(
            registration: registration,
            state: trustStore.state(of: match.id)
        )
    }

    public func registration(appIDs: Set<AppSyncAppID>,
                      advertisement: InstanceInboxAdvertisement?) throws -> AppSyncInstanceRegistration {
        try .init(
            instanceID: identity.publicIdentity.id,
            encryptionKey: identity.publicIdentity.encryptionKey,
            appIDs: appIDs,
            lanEndpoint: advertisement?.endpoint,
            lanAppendCapability: nil,
            signer: identity.journalSigner()
        )
    }

    public func stopLANServer() { discovery.stop(); server.stop() }

    @discardableResult
    public func trust(_ peer: AppSyncPeer) throws -> AppSyncTrustFact {
        let fact = try signedTrustFact(with: peer)
        _ = try trustStore.merge([fact])
        return fact
    }

    public func signedTrustFact(with peer: AppSyncPeer) throws -> AppSyncTrustFact {
        let timestamp = trustLock.withLock { trustClock.tick() }
        return try identity.trustFact(with: peer, timestamp: timestamp)
    }

    public func recordTrust(_ completed: AppSyncTrustFact) throws {
        trustLock.withLock { trustClock.observe(completed.timestamp) }
        _ = try trustStore.merge([completed])
    }

    @discardableResult
    public func revokeTrust(with peer: AppSyncPeer) throws -> AppSyncTrustFact {
        let timestamp = trustLock.withLock { trustClock.tick() }
        let fact = try AppSyncTrustFact(
            timestamp: timestamp, kind: .distrust,
            issuer: identity.publicIdentity, subject: peer
        ).signed(by: identity)
        _ = try trustStore.merge([fact])
        return fact
    }

    public func trusts(_ peer: AppSyncPeer) -> Bool { trustStore.trusts(peer.stableID) }

    /// Every instance this one trusts now.
    public func trustedPeers() -> Set<AppSyncPeerID> { trustStore.trustedPeers() }
}

struct LANHTTPResponse {
    let status: HTTPResponseStatus
    var body = Data()
    var contentType: String?
}

final class InboxAppendHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private let response: @Sendable (HTTPRequestHead, Data) -> LANHTTPResponse

    init(response: @escaping @Sendable (HTTPRequestHead, Data) -> LANHTTPResponse) {
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head; body.clear()
        case .body(var bytes):
            guard head != nil, body.readableBytes + bytes.readableBytes <= 256 * 1024 else {
                head = nil; return
            }
            body.writeBuffer(&bytes)
        case .end:
            let payload = Data(body.readBytes(length: body.readableBytes) ?? [])
            let response = head.map { response($0, payload) } ?? .init(status: .badRequest)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(response.body.count)")
            if let contentType = response.contentType {
                headers.add(name: "Content-Type", value: contentType)
            }
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(.init(
                version: .http1_1, status: response.status, headers: headers
            ))), promise: nil)
            if !response.body.isEmpty {
                var bytes = context.channel.allocator.buffer(capacity: response.body.count)
                bytes.writeBytes(response.body)
                context.write(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
            }
            // Close only once everything is written. Closing straight after
            // the flush discards whatever the socket's send buffer couldn't
            // take yet, cutting large replies (journal snapshots) short.
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}

public enum InstanceMessagingError: LocalizedError, Equatable {
    case instanceIdentityNotConfigured, credentialNotPersisted
    case encryptionFailed, invalidSignature, wrongRecipient, conflictingReplay
    case serverUnavailable
    /// DNS-SD refused to advertise or browse this instance on the LAN.
    case localNetworkDiscoveryFailed(operation: LocalNetworkDiscoveryOperation, code: Int32)

    public enum LocalNetworkDiscoveryOperation: String, Sendable {
        case advertise = "advertise this instance"
        case browse = "look for other instances"
    }

    /// kDNSServiceErr_PolicyDenied: local network privacy blocked the request.
    public static let dnsServicePolicyDenied: Int32 = -65570

    public var errorDescription: String? {
        switch self {
        case .instanceIdentityNotConfigured:
            "This instance has no identity keys, so peer messaging and trust changes are unavailable."
        case .credentialNotPersisted:
            "The credential store accepted this instance's identity keys but returned something else when they were read back."
        case .encryptionFailed: "The message could not be encrypted."
        case .invalidSignature: "The inbox message signature is invalid."
        case .wrongRecipient: "The inbox message belongs to another instance."
        case .conflictingReplay: "A different inbox message reused an existing identifier."
        case .serverUnavailable: "The local inbox server is unavailable."
        case let .localNetworkDiscoveryFailed(operation, code) where code == Self.dnsServicePolicyDenied:
            "Local network privacy stopped Hummingbird from trying to \(operation.rawValue). Allow it under System Settings › Privacy & Security › Local Network."
        case let .localNetworkDiscoveryFailed(operation, code):
            "Couldn't \(operation.rawValue) on the local network (DNS-SD error \(code))."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum VerificationEmoji {
    static let values = [
        "🐶", "🐱", "🦁", "🐎", "🦄", "🐷", "🐘", "🐰",
        "🐼", "🐓", "🐧", "🐢", "🐟", "🐙", "🦋", "🌷",
        "🌳", "🌵", "🍄", "🌏", "🌙", "☀️", "☁️", "🔥",
        "🍌", "🍎", "🍓", "🌽", "🍕", "🎂", "❤️", "😀",
        "🤖", "🎩", "👓", "🔧", "🎅", "👍", "☂️", "⌛️",
        "⏰", "🎁", "💡", "📕", "✏️", "📎", "✂️", "🔒",
        "🔑", "🔨", "☎️", "🏁", "🚂", "🚲", "✈️", "🚀",
        "🏆", "⚽️", "🎸", "🎺", "🔔", "⚓️", "🎧", "📁",
    ]

    static func render(_ digest: [UInt8]) -> String {
        digest.prefix(5).map { values[Int($0) % values.count] }.joined(separator: " ")
    }
}

private extension JSONEncoder {
    static var appSyncInbox: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var appSyncInbox: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
