import Crypto
import ATAppSync
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private enum PairingIdentityProvider {
    static let store = AppSyncPeerIdentityStore(credentialStore: AuthKeychain.store)
}

struct CredentialPairingRequest: Codable, Equatable, Sendable {
    static let scheme = "hummingbird"
    static let host = "credential-login"

    let endpoint: URL
    let secret: Data
    let pluginID: String
    let pluginSourceURL: URL
    let receiver: AppSyncPeer

    init(endpoint: URL, secret: Data, pluginID: String, pluginSourceURL: URL,
         receiver: AppSyncPeer = AppSyncPeerIdentity.generate().publicIdentity) {
        self.endpoint = endpoint
        self.secret = secret
        self.pluginID = pluginID
        self.pluginSourceURL = pluginSourceURL
        self.receiver = receiver
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let endpointText = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
              let endpoint = URL(string: endpointText), endpoint.scheme == "http",
              let pluginID = components.queryItems?.first(where: { $0.name == "plugin" })?.value,
              !pluginID.isEmpty,
              let sourceText = components.queryItems?.first(where: { $0.name == "source" })?.value,
              let pluginSourceURL = URL(string: sourceText), ["http", "https"].contains(pluginSourceURL.scheme),
              let secretText = components.queryItems?.first(where: { $0.name == "secret" })?.value,
              let secret = Data(base64URLEncoded: secretText), secret.count == 32,
              let receiverText = components.queryItems?.first(where: { $0.name == "receiver" })?.value,
              let receiverData = Data(base64URLEncoded: receiverText),
              let receiver = try? JSONDecoder().decode(AppSyncPeer.self, from: receiverData) else { return nil }
        self.init(endpoint: endpoint, secret: secret, pluginID: pluginID,
                  pluginSourceURL: pluginSourceURL, receiver: receiver)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
            URLQueryItem(name: "secret", value: secret.base64URLEncodedString()),
            URLQueryItem(name: "plugin", value: pluginID),
            URLQueryItem(name: "source", value: pluginSourceURL.absoluteString),
            URLQueryItem(name: "receiver", value: try! JSONEncoder().encode(receiver).base64URLEncodedString()),
        ]
        return components.url!
    }

    /// A compact, human-verifiable fingerprint of this session's symmetric
    /// key. Both devices require confirmation before credentials can move.
    var verificationEmoji: String {
        let emoji = [
            "🐶", "🐱", "🦁", "🐎", "🦄", "🐷", "🐘", "🐰",
            "🐼", "🐓", "🐧", "🐢", "🐟", "🐙", "🦋", "🌷",
            "🌳", "🌵", "🍄", "🌏", "🌙", "☀️", "☁️", "🔥",
            "🍌", "🍎", "🍓", "🌽", "🍕", "🎂", "❤️", "😀",
            "🤖", "🎩", "👓", "🔧", "🎅", "👍", "☂️", "⌛️",
            "⏰", "🎁", "💡", "📕", "✏️", "📎", "✂️", "🔒",
            "🔑", "🔨", "☎️", "🏁", "🚂", "🚲", "✈️", "🚀",
            "🏆", "⚽️", "🎸", "🎺", "🔔", "⚓️", "🎧", "📁",
        ]
        let digest = SHA256.hash(data: secret)
        return digest.prefix(7).map { emoji[Int($0) % emoji.count] }.joined(separator: " ")
    }

    var receiverVerificationEmoji: String { receiver.verificationEmoji(sessionSecret: secret) }
    func senderVerificationEmoji(_ sender: AppSyncPeer) -> String {
        sender.verificationEmoji(sessionSecret: secret)
    }

    func encrypted(_ auth: SourceAuth) throws -> Data {
        try encryptedPayload(.credentials(.init(
            pluginID: pluginID, pluginSourceURL: pluginSourceURL, auth: auth
        )))
    }

    fileprivate func encryptedPayload(_ payload: PairingPayload) throws -> Data {
        let plaintext = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: secret))
        guard let combined = box.combined else { throw PairingError.encryptionFailed }
        return combined
    }

    func decrypt(_ data: Data) throws -> SourceAuth {
        guard case .credentials(let transfer) = try decryptPayload(data),
              transfer.pluginID == pluginID, transfer.pluginSourceURL == pluginSourceURL
        else { throw PairingError.invalidRequest }
        return transfer.auth
    }

    fileprivate func decryptPayload(_ data: Data) throws -> PairingPayload {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: secret))
        return try JSONDecoder().decode(PairingPayload.self, from: plaintext)
    }

    fileprivate func statusProof(_ status: Int) -> String {
        let message = Data("hummingbird-pairing-status:\(status)".utf8)
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(code).base64URLEncodedString()
    }
}

struct CredentialTransfer: Codable, Equatable, Sendable {
    let pluginID: String
    let pluginSourceURL: URL
    let auth: SourceAuth
}

enum PairingPayload: Codable, Equatable, Sendable {
    case credentials(CredentialTransfer)
    case rejection
}

enum PairingError: LocalizedError, Equatable {
    case unavailable, invalidRequest, encryptionFailed, rejected

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Credential pairing is not available on the local network."
        case .invalidRequest: return "The credential pairing link is invalid."
        case .encryptionFailed: return "The credentials could not be encrypted."
        case .rejected: return "The receiving device rejected the credentials."
        }
    }
}

enum PairingRemoteStatus: Equatable {
    case waiting, accepted, rejected
}

private final class PairingWeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// A short-lived, one-shot HTTP receiver. The body is encrypted; possession of
/// the QR payload is required both to locate the listener and decrypt the result.
final class CredentialPairingReceiver: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private var consumed = false
    private var confirmed = false
    private var rejected = false
    private var stopped = false
    private var requestValue: CredentialPairingRequest?
    private let identity: AppSyncPeerIdentity?
    private let messageStore: AppSyncMessageStore?
    private var senderIdentity: AppSyncPeer?
    private let pluginID: String
    private let pluginSourceURL: URL
    private let onReceive: @MainActor (SourceAuth) -> Void
    private let onReject: @MainActor () -> Void

    init(pluginID: String, pluginSourceURL: URL,
         identity: AppSyncPeerIdentity? = nil,
         messageStore suppliedMessageStore: AppSyncMessageStore? = nil,
         onReceive: @escaping @MainActor (SourceAuth) -> Void,
         onReject: @escaping @MainActor () -> Void = {}) {
        self.pluginID = pluginID
        self.pluginSourceURL = pluginSourceURL
        let resolvedIdentity = identity ?? (try? PairingIdentityProvider.store.identity())
        self.identity = resolvedIdentity
        if let suppliedMessageStore {
            messageStore = suppliedMessageStore
        } else if let resolvedIdentity {
            let file = Storage.directory.appendingPathComponent("peer-messages", isDirectory: true)
                .appendingPathComponent("\(resolvedIdentity.publicIdentity.id.uuidString.lowercased()).json")
            messageStore = try? AppSyncMessageStore(identity: resolvedIdentity, fileURL: file)
        } else {
            messageStore = nil
        }
        self.onReceive = onReceive
        self.onReject = onReject
    }

    deinit { stop() }

    func start() async throws -> CredentialPairingRequest {
        if let requestValue { return requestValue }
        guard let identity else { throw AppSyncPeerError.credentialStoreUnavailable }
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let receiver = PairingWeakReference(self)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CredentialPairingHTTPHandler {
                        head, body in
                        receiver.value?.respond(to: head, body: body, secret: secret)
                            ?? PairingHTTPResponse(status: .gone)
                    })
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            throw PairingError.unavailable
        }
        let host = ProcessInfo.processInfo.hostName.isEmpty ? "localhost" : ProcessInfo.processInfo.hostName
        var endpoint = URLComponents()
        endpoint.scheme = "http"
        endpoint.host = host
        endpoint.port = port
        endpoint.path = "/credentials"
        guard let endpointURL = endpoint.url else {
            try? await channel.close()
            throw PairingError.unavailable
        }
        let request = CredentialPairingRequest(
            endpoint: endpointURL, secret: secret, pluginID: pluginID,
            pluginSourceURL: pluginSourceURL, receiver: identity.publicIdentity
        )
        lock.withLock {
            self.channel = channel
            requestValue = request
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            self?.stop()
        }
        return request
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let channel = self.channel
        self.channel = nil
        lock.unlock()
        channel?.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    func confirmVerification() {
        lock.lock()
        confirmed = senderIdentity != nil
        lock.unlock()
    }

    func rejectVerification() {
        lock.lock()
        rejected = true
        lock.unlock()
    }

    private func respond(to head: HTTPRequestHead, body: Data, secret: Data) -> PairingHTTPResponse {
        guard let identity else { return .init(status: .serviceUnavailable) }
        if head.method == .GET, head.uri == "/status" {
            lock.lock()
            let status: HTTPResponseStatus = rejected ? .conflict : (confirmed ? .ok : (consumed ? .gone : .noContent))
            lock.unlock()
            let request = CredentialPairingRequest(
                endpoint: URL(string: "http://localhost")!, secret: secret,
                pluginID: pluginID, pluginSourceURL: pluginSourceURL, receiver: identity.publicIdentity
            )
            return PairingHTTPResponse(status: status, proof: request.statusProof(Int(status.code)))
        }
        guard head.method == .POST else { return .init(status: .badRequest) }
        if head.uri == "/hello" {
            return .init(status: acceptHello(body, secret: secret) ? .noContent : .badRequest)
        }
        if head.uri == "/reject" {
            return .init(status: acceptRejection(body, secret: secret) ? .noContent : .badRequest)
        }
        if head.uri == "/credentials" {
            return .init(status: accept(body, secret: secret) ? .noContent : .badRequest)
        }
        return .init(status: .notFound)
    }

    private func accept(_ data: Data, secret: Data) -> Bool {
        guard let messageStore else { return false }
        lock.lock()
        guard confirmed, !rejected, !consumed else { lock.unlock(); return false }
        consumed = true
        lock.unlock()
        guard let envelope = try? JSONDecoder().decode(AppSyncSealedMessage.self, from: data),
              envelope.sender == senderIdentity,
              (try? messageStore.appendRemote(envelope)) != nil,
              case .credentials(let transfer) = try? messageStore.open(envelope, as: PairingPayload.self),
              transfer.pluginID == pluginID, transfer.pluginSourceURL == pluginSourceURL,
              !transfer.auth.isEmpty else {
            lock.lock(); consumed = false; lock.unlock()
            return false
        }
        Task { @MainActor [onReceive] in onReceive(transfer.auth) }
        try? messageStore.deleteLocal(id: envelope.id)
        stop()
        return true
    }

    private func acceptRejection(_ data: Data, secret: Data) -> Bool {
        guard let messageStore else { return false }
        guard let envelope = try? JSONDecoder().decode(AppSyncSealedMessage.self, from: data),
              (try? messageStore.appendRemote(envelope)) != nil,
              case .rejection = try? messageStore.open(envelope, as: PairingPayload.self) else { return false }
        lock.lock()
        guard !consumed else { lock.unlock(); return false }
        consumed = true
        rejected = true
        lock.unlock()
        Task { @MainActor [onReject] in onReject() }
        try? messageStore.deleteLocal(id: envelope.id)
        return true
    }

    private func acceptHello(_ data: Data, secret: Data) -> Bool {
        guard let hello = try? JSONDecoder().decode(PairingHello.self, from: data),
              hello.proof == hello.identityProof(secret: secret) else { return false }
        lock.withLock { senderIdentity = hello.sender }
        return true
    }

    var remoteSender: AppSyncPeer? { lock.withLock { senderIdentity } }
}

private struct PairingHello: Codable {
    let sender: AppSyncPeer
    let proof: Data

    init(sender: AppSyncPeer, secret: Data) {
        self.sender = sender
        proof = Self.proof(sender: sender, secret: secret)
    }

    func identityProof(secret: Data) -> Data { Self.proof(sender: sender, secret: secret) }
    private static func proof(sender: AppSyncPeer, secret: Data) -> Data {
        var data = Data(sender.id.uuidString.lowercased().utf8)
        data.append(sender.signingKey)
        data.append(sender.encryptionKey)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
    }
}

private struct PairingHTTPResponse: Sendable {
    let status: HTTPResponseStatus
    var proof: String? = nil
}

private final class CredentialPairingHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private let response: @Sendable (HTTPRequestHead, Data) -> PairingHTTPResponse

    init(response: @escaping @Sendable (HTTPRequestHead, Data) -> PairingHTTPResponse) { self.response = response }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
        case .body(var bytes):
            guard head != nil, body.readableBytes + bytes.readableBytes <= 64 * 1024 else {
                head = nil
                return
            }
            body.writeBuffer(&bytes)
        case .end:
            let payload = Data(body.readBytes(length: body.readableBytes) ?? [])
            let result = head.map { response($0, payload) } ?? PairingHTTPResponse(status: .badRequest)
            respond(context: context, result: result)
        }
    }

    private func respond(context: ChannelHandlerContext, result: PairingHTTPResponse) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        if let proof = result.proof { headers.add(name: "X-Hummingbird-Pairing-Proof", value: proof) }
        context.write(wrapOutboundOut(.head(.init(version: .http1_1, status: result.status, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.close(promise: nil)
    }
}

extension CredentialPairingRequest {
    func send(_ auth: SourceAuth, sender supplied: AppSyncPeerIdentity? = nil,
              session: URLSession = .shared) async throws {
        let sender = try supplied ?? PairingIdentityProvider.store.identity()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(AppSyncSealedMessage.seal(
            PairingPayload.credentials(.init(
                pluginID: pluginID, pluginSourceURL: pluginSourceURL, auth: auth
            )), appID: HummingbirdProfileSchema.appID, from: sender, to: receiver
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw PairingError.rejected }
    }

    func reject(sender supplied: AppSyncPeerIdentity? = nil, session: URLSession = .shared) async throws {
        let sender = try supplied ?? PairingIdentityProvider.store.identity()
        let envelope = try AppSyncSealedMessage.seal(
            PairingPayload.rejection, appID: HummingbirdProfileSchema.appID,
            from: sender, to: receiver
        )
        try await post(try JSONEncoder().encode(envelope), to: endpoint.deletingLastPathComponent().appendingPathComponent("reject"), session: session)
    }


    func announceSender(_ supplied: AppSyncPeerIdentity? = nil,
                        session: URLSession = .shared) async throws -> AppSyncPeer {
        let identity = try supplied ?? PairingIdentityProvider.store.identity()
        let hello = PairingHello(sender: identity.publicIdentity, secret: secret)
        try await post(try JSONEncoder().encode(hello),
                       to: endpoint.deletingLastPathComponent().appendingPathComponent("hello"), session: session)
        return identity.publicIdentity
    }

    func remoteStatus(session: URLSession = .shared) async throws -> PairingRemoteStatus {
        let statusURL = endpoint.deletingLastPathComponent().appendingPathComponent("status")
        let (_, response) = try await session.data(from: statusURL)
        guard let response = response as? HTTPURLResponse else { throw PairingError.rejected }
        let status = response.statusCode
        guard response.value(forHTTPHeaderField: "X-Hummingbird-Pairing-Proof") == statusProof(status) else {
            throw PairingError.rejected
        }
        switch status {
        case 200: return .accepted
        case 204: return .waiting
        case 409: return .rejected
        default: throw PairingError.rejected
        }
    }

    private func post(_ data: Data, to url: URL, session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw PairingError.rejected }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
