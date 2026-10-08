import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

struct CredentialPairingRequest: Codable, Equatable, Sendable {
    static let scheme = "hummingbird"
    static let host = "credential-login"

    let endpoint: URL
    let secret: Data
    let pluginID: String
    let pluginSourceURL: URL

    init(endpoint: URL, secret: Data, pluginID: String, pluginSourceURL: URL) {
        self.endpoint = endpoint
        self.secret = secret
        self.pluginID = pluginID
        self.pluginSourceURL = pluginSourceURL
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
              let secret = Data(base64URLEncoded: secretText), secret.count == 32 else { return nil }
        self.init(endpoint: endpoint, secret: secret, pluginID: pluginID, pluginSourceURL: pluginSourceURL)
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

    func encrypted(_ auth: SourceAuth) throws -> Data {
        try encryptedPayload(.credentials(auth))
    }

    fileprivate func encryptedPayload(_ payload: PairingPayload) throws -> Data {
        let plaintext = try JSONEncoder().encode(payload)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: secret))
        guard let combined = box.combined else { throw PairingError.encryptionFailed }
        return combined
    }

    func decrypt(_ data: Data) throws -> SourceAuth {
        guard case .credentials(let auth) = try decryptPayload(data) else { throw PairingError.invalidRequest }
        return auth
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

fileprivate enum PairingPayload: Codable {
    case credentials(SourceAuth)
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
    private let pluginID: String
    private let pluginSourceURL: URL
    private let onReceive: @MainActor (SourceAuth) -> Void
    private let onReject: @MainActor () -> Void

    init(pluginID: String, pluginSourceURL: URL,
         onReceive: @escaping @MainActor (SourceAuth) -> Void,
         onReject: @escaping @MainActor () -> Void = {}) {
        self.pluginID = pluginID
        self.pluginSourceURL = pluginSourceURL
        self.onReceive = onReceive
        self.onReject = onReject
    }

    deinit { stop() }

    func start() async throws -> CredentialPairingRequest {
        if let requestValue { return requestValue }
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(CredentialPairingHTTPHandler {
                        [weak self] head, body in
                        self?.respond(to: head, body: body, secret: secret) ?? PairingHTTPResponse(status: .gone)
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
            endpoint: endpointURL, secret: secret, pluginID: pluginID, pluginSourceURL: pluginSourceURL
        )
        lock.lock()
        self.channel = channel
        requestValue = request
        lock.unlock()
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
        confirmed = true
        lock.unlock()
    }

    func rejectVerification() {
        lock.lock()
        rejected = true
        lock.unlock()
    }

    private func respond(to head: HTTPRequestHead, body: Data, secret: Data) -> PairingHTTPResponse {
        if head.method == .GET, head.uri == "/status" {
            lock.lock()
            let status: HTTPResponseStatus = rejected ? .conflict : (confirmed ? .ok : (consumed ? .gone : .noContent))
            lock.unlock()
            let request = CredentialPairingRequest(
                endpoint: URL(string: "http://localhost")!, secret: secret,
                pluginID: pluginID, pluginSourceURL: pluginSourceURL
            )
            return PairingHTTPResponse(status: status, proof: request.statusProof(Int(status.code)))
        }
        guard head.method == .POST else { return .init(status: .badRequest) }
        if head.uri == "/reject" {
            return .init(status: acceptRejection(body, secret: secret) ? .noContent : .badRequest)
        }
        if head.uri == "/credentials" {
            return .init(status: accept(body, secret: secret) ? .noContent : .badRequest)
        }
        return .init(status: .notFound)
    }

    private func accept(_ data: Data, secret: Data) -> Bool {
        lock.lock()
        guard confirmed, !rejected, !consumed else { lock.unlock(); return false }
        consumed = true
        lock.unlock()
        let request = CredentialPairingRequest(
            endpoint: URL(string: "http://localhost")!, secret: secret,
            pluginID: pluginID, pluginSourceURL: pluginSourceURL
        )
        guard let auth = try? request.decrypt(data), !auth.isEmpty else {
            lock.lock(); consumed = false; lock.unlock()
            return false
        }
        Task { @MainActor [onReceive] in onReceive(auth) }
        stop()
        return true
    }

    private func acceptRejection(_ data: Data, secret: Data) -> Bool {
        let request = CredentialPairingRequest(
            endpoint: URL(string: "http://localhost")!, secret: secret,
            pluginID: pluginID, pluginSourceURL: pluginSourceURL
        )
        guard case .rejection = try? request.decryptPayload(data) else { return false }
        lock.lock()
        guard !consumed else { lock.unlock(); return false }
        consumed = true
        rejected = true
        lock.unlock()
        Task { @MainActor [onReject] in onReject() }
        return true
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
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

extension CredentialPairingRequest {
    func send(_ auth: SourceAuth, session: URLSession = .shared) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try encrypted(auth)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw PairingError.rejected }
    }

    func reject(session: URLSession = .shared) async throws {
        try await post(try encryptedPayload(.rejection), to: endpoint.deletingLastPathComponent().appendingPathComponent("reject"), session: session)
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
