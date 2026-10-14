import Crypto
import ATProtoKit
import Foundation
import CredentialStorage
import NIOCore
import NIOHTTP1
import NIOPosix

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

    fileprivate struct Stored: Codable {
        let id: UUID
        let signingKey: Data
        let encryptionKey: Data
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
            let profileData = credentialStore.load(account: account)
            let storedData = profileData
                ?? (migrateLegacyIdentity ? credentialStore.load(account: Self.legacyAccount) : nil)
            if let data = storedData,
               let stored = try? JSONDecoder().decode(InstanceIdentity.Stored.self, from: data) {
                let identity = try InstanceIdentity(stored: stored)
                if profileData == nil {
                    credentialStore.save(data, account: account)
                }
                cached = identity
                return identity
            }
            let identity = InstanceIdentity.generate()
            let data = try JSONEncoder().encode(identity.stored)
            credentialStore.save(data, account: account)
            guard credentialStore.load(account: account) == data else {
                throw InstanceMessagingError.credentialStoreUnavailable
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
        let stored = fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder.appSyncInbox.decode(Snapshot.self, from: $0) }
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
        try JSONEncoder.appSyncInbox.encode(snapshot).write(to: fileURL, options: [.atomic])
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
                        if head.method == .POST, head.uri == "/appsync/v1/sync" {
                            return self.syncResponse(data, appIDs: appIDs)
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
        guard let envelope = try? JSONDecoder().decode(InstanceInboxEnvelope.self, from: data),
              appIDs.contains(envelope.appID), trustStore.trusts(envelope.sender.stableID),
              let request = try? inbox.open(envelope, as: AppSyncLANRequest.self),
              request.appID == envelope.appID else { return .init(status: .forbidden) }
        do {
            let journal = lock.withLock { self.journal }
            let events = journal?.events() ?? []
            let batch = try events.isEmpty ? nil : journal?.signedBatch(
                type: NSID(rawValue: "com.eightybps.appsync.journal")!, mutations: events
            )
            let snapshot = AppSyncLANSnapshot(
                nonce: request.nonce, journal: batch, trustFacts: trustStore.facts()
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
    }

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

    public func peers(appIDs: Set<AppSyncAppID>) -> [AppSyncPeerTrustSummary] {
        trustStore.peers(among: discovery.registrations(), localAppIDs: appIDs)
    }

    @discardableResult
    public func verifyPeer(
        _ code: AppSyncPeerVerificationCode, appIDs: Set<AppSyncAppID>
    ) throws -> AppSyncPeerTrustSummary {
        let compatible = peers(appIDs: appIDs)
        guard let match = compatible.first(where: { $0.id == code.peerID }) else {
            throw AppSyncPeerVerificationError.peerNotFound
        }
        _ = try trust(match.peer)
        return .init(
            registration: match.registration,
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
}

private struct LANHTTPResponse {
    let status: HTTPResponseStatus
    var body = Data()
    var contentType: String?
}

private final class InboxAppendHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
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
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.close(promise: nil)
        }
    }
}

public enum InstanceMessagingError: LocalizedError, Equatable {
    case credentialStoreUnavailable, encryptionFailed, invalidSignature, wrongRecipient, conflictingReplay
    case serverUnavailable

    public var errorDescription: String? {
        switch self {
        case .credentialStoreUnavailable: "A protected credential store is unavailable."
        case .encryptionFailed: "The message could not be encrypted."
        case .invalidSignature: "The inbox message signature is invalid."
        case .wrongRecipient: "The inbox message belongs to another instance."
        case .conflictingReplay: "A different inbox message reused an existing identifier."
        case .serverUnavailable: "The local inbox server is unavailable."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private enum VerificationEmoji {
    private static let values = [
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
