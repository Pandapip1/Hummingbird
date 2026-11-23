import Foundation
import NIOCore
import NIOPosix
import Synchronization
#if canImport(Network)
import Network
#endif

/// A loopback HTTP CONNECT proxy that every connection a plugin causes goes
/// through: its HTTP client and its hidden browser page. For each connection
/// it resolves the host once, checks the address with the plugin's
/// `PluginNetworkPolicy`, and connects to exactly that checked address, so a
/// DNS answer that changes between check and connect (rebinding) cannot send
/// the connection anywhere else. TLS stays end to end between the client and
/// the origin: the proxy only ever sees `CONNECT host:port`.
///
/// One proxy per plugin runtime, on an ephemeral 127.0.0.1 port. Denials are
/// remembered per host:port so the failed request reports why.
final class PluginEgressProxy: Sendable {
    /// One event loop thread serves every plugin's proxy; it only shuffles bytes.
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    static let maximumHeadBytes = 8 * 1024

    final class Shared: Sendable {
        let policy: PluginNetworkPolicy
        let maximumConnections: Int
        let denials = Mutex<[String: NetworkDenial]>([:])
        let connected = Mutex<[CheckedDestination]>([])
        let active = Mutex(0)
        /// Accepted connections, so a suspension (and its simulation) can close them.
        let connections = Mutex<[ObjectIdentifier: any Channel]>([:])

        init(policy: PluginNetworkPolicy, maximumConnections: Int) {
            self.policy = policy
            self.maximumConnections = maximumConnections
        }

        func recordDenial(_ denial: NetworkDenial, host: String, port: Int) {
            denials.withLock { $0["\(PluginNetworkPolicy.normalizedHost(host)):\(port)"] = denial }
        }

        func recordConnection(_ destination: CheckedDestination) {
            connected.withLock { list in
                list.append(destination)
                if list.count > 64 { list.removeFirst(list.count - 64) }
            }
        }
    }

    let port: Int
    private let server: any Channel
    let shared: Shared

    private init(port: Int, server: any Channel, shared: Shared) {
        self.port = port
        self.server = server
        self.shared = shared
    }

    /// Binds a new proxy for `policy`. Blocks briefly; never call on the main thread.
    static func start(policy: PluginNetworkPolicy, maximumConnections: Int = PluginLimits.maximumConcurrentConnections) throws -> PluginEgressProxy {
        let shared = Shared(policy: policy, maximumConnections: maximumConnections)
        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                shared.connections.withLock { $0[ObjectIdentifier(child)] = child }
                child.closeFuture.whenComplete { _ in shared.connections.withLock { $0[ObjectIdentifier(child)] = nil } }
                return                 child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ConnectHandler(shared: shared))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        guard let port = server.localAddress?.port else {
            server.close(promise: nil)
            throw NetworkDenial.invalid
        }
        let proxy = PluginEgressProxy(port: port, server: server, shared: shared)
        LoopbackLifecycle.shared.register(proxy)
        return proxy
    }

    func close() { server.close(promise: nil) }

    /// Why the proxy last refused `host:port`, if it did.
    func denial(host: String, port: Int) -> NetworkDenial? {
        shared.denials.withLock { $0["\(PluginNetworkPolicy.normalizedHost(host)):\(port)"] }
    }

    /// The destinations the proxy connected to, most recent last (tests, diagnostics).
    var connectedDestinations: [CheckedDestination] { shared.connected.withLock { $0 } }

    /// Routes a URL session's connections through this proxy, with no
    /// fallback to a direct connection.
    func apply(to configuration: URLSessionConfiguration) {
        #if canImport(Network)
        configuration.proxyConfigurations = [proxyConfiguration]
        #endif
    }

    #if canImport(Network)
    /// The proxy as Network.framework sees it; URLSession and WebKit data
    /// stores take this. Failover to a direct connection is off.
    var proxyConfiguration: ProxyConfiguration {
        var configuration = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!),
            tlsOptions: nil
        )
        configuration.allowFailover = false
        configuration.excludedDomains = []
        return configuration
    }
    #endif

    /// Whether URL sessions are routed through the proxy on this platform. On
    /// Linux, swift-corelibs-foundation ignores proxy settings, so plugin HTTP
    /// there is checked before connecting only (see Documentation/PluginSecurity.md).
    static var pinsURLSessionConnections: Bool {
        #if canImport(Network)
        true
        #else
        false
        #endif
    }
}

// MARK: - Handlers

/// Reads the CONNECT head, checks the destination off the event loop, then
/// connects to the checked address and glues the two channels together.
private final class ConnectHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State { case readingHead, checking, connecting, done }

    private let shared: PluginEgressProxy.Shared
    private var state = State.readingHead
    private var buffered: ByteBuffer?

    init(shared: PluginEgressProxy.Shared) { self.shared = shared }

    /// A client that never finishes its CONNECT head is dropped, so idle sockets cannot hold slots.
    func handlerAdded(context: ChannelHandlerContext) {
        let loop = context.eventLoop
        let boundSelf = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        loop.scheduleTask(in: .seconds(10)) {
            if boundSelf.value.state == .readingHead { boundContext.value.close(promise: nil) }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        if buffered == nil { buffered = bytes } else { buffered!.writeBuffer(&bytes) }
        guard state == .readingHead, let buffer = buffered else { return }
        let view = buffer.readableBytesView
        guard let end = view.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if buffer.readableBytes > PluginEgressProxy.maximumHeadBytes { refuse(context, status: "431 Request Header Fields Too Large") }
            return
        }
        let head = String(decoding: view[view.startIndex..<end.lowerBound], as: UTF8.self)
        buffered!.moveReaderIndex(forwardBy: end.upperBound - view.startIndex)
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "CONNECT", let (host, port) = Self.authority(String(parts[1])) else {
            refuse(context, status: "405 Method Not Allowed")
            return
        }
        guard shared.active.withLock({ $0 }) < shared.maximumConnections else {
            refuse(context, status: "503 Service Unavailable")
            return
        }
        state = .checking
        let policy = shared.policy
        let loop = context.eventLoop
        let boundSelf = NIOLoopBound(self, eventLoop: loop)
        let boundContext = NIOLoopBound(context, eventLoop: loop)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = policy.check(host: host, port: port)
            loop.execute { boundSelf.value.checked(result, host: host, port: port, context: boundContext.value) }
        }
    }

    static func authority(_ text: String) -> (String, Int)? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        let host = String(text[..<colon])
        guard !host.isEmpty, !host.contains(":") else { return nil }
        return (host, port)
    }

    private func checked(_ result: Result<CheckedDestination, NetworkDenial>, host: String, port: Int, context: ChannelHandlerContext) {
        guard state == .checking, context.channel.isActive else { return }
        switch result {
        case .failure(let denial):
            shared.recordDenial(denial, host: host, port: port)
            refuse(context, status: "403 Forbidden")
        case .success(let destination):
            state = .connecting
            let address: SocketAddress
            do { address = try SocketAddress(ipAddress: destination.address.description, port: destination.port) } catch {
                refuse(context, status: "502 Bad Gateway")
                return
            }
            let loop = context.eventLoop
            let boundSelf = NIOLoopBound(self, eventLoop: loop)
            let boundContext = NIOLoopBound(context, eventLoop: loop)
            ClientBootstrap(group: loop)
                .connectTimeout(.seconds(15))
                .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .connect(to: address)
                .whenComplete { outcome in
                    switch outcome {
                    case .success(let upstream): boundSelf.value.connected(upstream, destination: destination, context: boundContext.value)
                    case .failure: boundSelf.value.refuse(boundContext.value, status: "502 Bad Gateway")
                    }
                }
        }
    }

    private func connected(_ upstream: any Channel, destination: CheckedDestination, context: ChannelHandlerContext) {
        guard context.channel.isActive else { upstream.close(promise: nil); return }
        state = .done
        shared.recordConnection(destination)
        shared.active.withLock { $0 += 1 }
        let shared = self.shared
        upstream.closeFuture.whenComplete { _ in shared.active.withLock { $0 -= 1 } }
        let (local, remote) = GlueHandler.matchedPair()
        do {
            try context.pipeline.syncOperations.addHandler(local)
            try upstream.pipeline.syncOperations.addHandler(remote)
        } catch {
            upstream.close(promise: nil)
            context.close(promise: nil)
            return
        }
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n")), promise: nil)
        if let rest = buffered, rest.readableBytes > 0 { upstream.writeAndFlush(rest, promise: nil) }
        buffered = nil
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    fileprivate func refuse(_ context: ChannelHandlerContext, status: String) {
        state = .done
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response))).whenComplete { _ in }
        context.close(promise: nil)
    }
}

/// Forwards bytes between two channels on the same event loop, with backpressure.
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerWriteEOF() }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { partner?.partnerCloseFull() }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable { context.read() } else { pendingRead = true }
    }
}

/// Fails every request. A session that must go through the egress proxy
/// uses it when the proxy could not start, so it fails closed.
final class RefusingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

extension PluginEgressProxy: SuspendedResource {
    func resumeAfterSuspension() async -> PortMove? { nil }

    func reclaimAsSuspensionWould() async {
        let open = shared.connections.withLock { open in defer { open = [:] }; return Array(open.values) }
        try? await server.close()
        for child in open { try? await child.close() }
    }
}
