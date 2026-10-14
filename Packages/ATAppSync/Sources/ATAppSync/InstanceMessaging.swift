import Crypto
import ATProtoKit
import Foundation
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

public protocol AppSyncCredentialStore: Sendable {
    func load(account: String) -> Data?
    func save(_ data: Data?, account: String)
}

public struct InstancePublicIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public let signingKey: Data
    public let encryptionKey: Data

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
}

public final class InstanceIdentityStore: @unchecked Sendable {
    private static let account = "com.eightybps.appsync.instance-identity.v1"
    private let credentialStore: any AppSyncCredentialStore
    private let lock = NSLock()
    private var cached: InstanceIdentity?

    public init(credentialStore: any AppSyncCredentialStore) { self.credentialStore = credentialStore }

    public func identity() throws -> InstanceIdentity {
        try lock.withLock {
            if let cached { return cached }
            if let data = credentialStore.load(account: Self.account),
               let stored = try? JSONDecoder().decode(InstanceIdentity.Stored.self, from: data) {
                let identity = try InstanceIdentity(stored: stored)
                cached = identity
                return identity
            }
            let identity = InstanceIdentity.generate()
            let data = try JSONEncoder().encode(identity.stored)
            credentialStore.save(data, account: Self.account)
            guard credentialStore.load(account: Self.account) == data else {
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
    private let inbox: InstanceInbox
    private let capability: Data
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private(set) var endpoint: URL?

    public init(inbox: InstanceInbox, capability: Data) {
        self.inbox = inbox
        self.capability = capability
    }

    deinit { stop() }

    public func start() async throws -> URL {
        if let endpoint = lock.withLock({ endpoint }) { return endpoint }
        let expected = capability.base64URLEncodedString()
        let inbox = self.inbox
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(InboxAppendHTTPHandler { head, data in
                        guard head.method == .POST, head.uri == "/inbox",
                              head.headers.first(name: "Authorization") == "Bearer \(expected)",
                              let envelope = try? JSONDecoder().decode(InstanceInboxEnvelope.self, from: data)
                        else { return .forbidden }
                        do { try inbox.appendRemote(envelope); return .noContent }
                        catch { return .badRequest }
                    })
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
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

    public func stop() {
        let channel = lock.withLock { () -> Channel? in
            let value = self.channel
            self.channel = nil
            endpoint = nil
            return value
        }
        channel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}

public struct InstanceInboxAdvertisement: Codable, Hashable, Sendable {
    public let identity: InstancePublicIdentity
    public let endpoint: URL
    /// A write-only capability shared only inside the account's permissioned
    /// profile space or an explicitly verified pairing ceremony.
    public let appendCapability: Data
}

public final class InstanceMessagingService: @unchecked Sendable {
    private static let capabilityAccount = "com.eightybps.appsync.instance-inbox-capability.v1"
    public let identity: InstanceIdentity
    public let inbox: InstanceInbox
    public var peer: AppSyncPeerIdentity { identity }
    public var messageStore: AppSyncMessageStore { inbox }
    private let capability: Data
    private let server: InstanceInboxLANServer

    public init(credentialStore: any AppSyncCredentialStore, storageDirectory: URL) throws {
        identity = try InstanceIdentityStore(credentialStore: credentialStore).identity()
        let file = storageDirectory.appendingPathComponent("instance-inbox", isDirectory: true)
            .appendingPathComponent("\(identity.publicIdentity.id.uuidString.lowercased()).json")
        inbox = try InstanceInbox(identity: identity, fileURL: file)
        if let stored = credentialStore.load(account: Self.capabilityAccount), stored.count == 32 {
            capability = stored
        } else {
            var generator = SystemRandomNumberGenerator()
            let created = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            credentialStore.save(created, account: Self.capabilityAccount)
            guard credentialStore.load(account: Self.capabilityAccount) == created else {
                throw InstanceMessagingError.credentialStoreUnavailable
            }
            capability = created
        }
        server = InstanceInboxLANServer(inbox: inbox, capability: capability)
    }

    public func startLANServer() async throws -> InstanceInboxAdvertisement {
        .init(identity: identity.publicIdentity, endpoint: try await server.start(),
              appendCapability: capability)
    }

    public func registration(appIDs: Set<AppSyncAppID>,
                      advertisement: InstanceInboxAdvertisement?) throws -> AppSyncInstanceRegistration {
        try .init(
            instanceID: identity.publicIdentity.id,
            encryptionKey: identity.publicIdentity.encryptionKey,
            appIDs: appIDs,
            lanEndpoint: advertisement?.endpoint,
            lanAppendCapability: advertisement?.appendCapability,
            signer: identity.journalSigner()
        )
    }

    public func stopLANServer() { server.stop() }
}

private final class InboxAppendHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private let response: @Sendable (HTTPRequestHead, Data) -> HTTPResponseStatus

    init(response: @escaping @Sendable (HTTPRequestHead, Data) -> HTTPResponseStatus) {
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
            let status = head.map { response($0, payload) } ?? .badRequest
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "0")
            headers.add(name: "Connection", value: "close")
            context.write(wrapOutboundOut(.head(.init(
                version: .http1_1, status: status, headers: headers
            ))), promise: nil)
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
