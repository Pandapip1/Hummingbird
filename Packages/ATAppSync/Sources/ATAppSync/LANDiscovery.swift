import CDNSService
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Standard DNS-SD presence for AppSync instances. DNS-SD only supplies a
/// routable HTTP endpoint and expected key digest; the signed registration at
/// that endpoint remains the authority for identity, capabilities, and apps.
///
/// An instance counts as present while its advertisement exists: its signed
/// registration is fetched when the advertisement resolves and again every
/// `refreshInterval`, and it is dropped as soon as DNS-SD reports the
/// advertisement gone. `lifetime` only bounds how long a registration
/// survives without a successful refresh, for hosts that vanish without a
/// goodbye.
final class AppSyncLANDiscovery: @unchecked Sendable {
    private static let serviceType = AppSyncAuthority.bonjourServiceType
    private static let lifetime: TimeInterval = 90
    private static let refreshInterval: TimeInterval = 30

    private struct Seen {
        let registration: AppSyncInstanceRegistration
        let receivedAt: Date
    }

    /// A DNS-SD operation and the dispatch source that services its socket.
    private struct Operation {
        let reference: DNSServiceRef
        let source: DispatchSourceRead?
    }

    /// One advertisement, as seen on one interface.
    private struct AdvertKey: Hashable {
        let name: String
        let interfaceIndex: UInt32
    }

    /// Where an advertisement's signed registration is served.
    private struct Endpoint: Hashable {
        let url: URL
        let peerID: AppSyncPeerID
    }

    private struct Advert {
        let resolver: Operation
        var endpoint: Endpoint?
    }

    private let lock = NSLock()
    /// Every DNS-SD callback runs here, so tearing down on this queue
    /// guarantees none is mid-flight.
    private let queue = DispatchQueue(label: "com.eightybps.appsync.dnssd")
    private static let queueKey = DispatchSpecificKey<Void>()
    /// Registration fetches share nothing (cookies, cache, credentials) with
    /// the host app's other traffic.
    private let session = URLSession(configuration: .ephemeral)
    private var registration: Operation?
    private var browser: Operation?
    private var adverts: [AdvertKey: Advert] = [:]
    private var refreshTimer: DispatchSourceTimer?
    private var seen: [AppSyncPeerID: Seen] = [:]

    init() {
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    func start(advertising registration: AppSyncInstanceRegistration) async throws {
        try registration.verify()
        guard let endpoint = registration.lanEndpoint,
              let port = endpoint.port, (1...Int(UInt16.max)).contains(port) else {
            throw InstanceMessagingError.serverUnavailable
        }
        if lock.withLock({ self.registration != nil }) { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        var registerRef: DNSServiceRef?
        let txt = Self.txtRecord(peerID: registration.stablePeerID)
        let registerError = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &registerRef, 0, 0,
                registration.stablePeerID.rawValue,
                Self.serviceType, nil, nil, UInt16(port).bigEndian,
                UInt16(bytes.count), bytes.baseAddress,
                appSyncRegisterReply, context
            )
        }
        guard registerError == kDNSServiceErr_NoError, let registerRef else {
            throw InstanceMessagingError.localNetworkDiscoveryFailed(
                operation: .advertise, code: registerError)
        }

        var browseRef: DNSServiceRef?
        let browseError = DNSServiceBrowse(
            &browseRef, 0, 0, Self.serviceType, nil, appSyncBrowseReply, context
        )
        guard browseError == kDNSServiceErr_NoError, let browseRef else {
            DNSServiceRefDeallocate(registerRef)
            throw InstanceMessagingError.localNetworkDiscoveryFailed(
                operation: .browse, code: browseError)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.refreshInterval, repeating: Self.refreshInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }

        let register = Operation(reference: registerRef, source: monitor(registerRef))
        let browse = Operation(reference: browseRef, source: monitor(browseRef))
        lock.withLock {
            self.registration = register
            self.browser = browse
            self.refreshTimer = timer
        }
        timer.resume()
    }

    func registrations() -> [AppSyncInstanceRegistration] {
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        return lock.withLock {
            seen = seen.filter { $0.value.receivedAt >= cutoff }
            return seen.values.map(\.registration)
        }
    }

    func observe(_ registration: AppSyncInstanceRegistration) throws {
        try registration.verify()
        lock.withLock {
            seen[registration.stablePeerID] = Seen(
                registration: registration, receivedAt: Date()
            )
        }
    }

    /// Ends advertising and browsing. Callbacks reach this object through an
    /// unretained pointer, so the sources are cancelled on their own queue:
    /// once cancelled there, no callback can be running or start again.
    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            tearDown()
        } else {
            queue.sync { tearDown() }
        }
    }

    private func tearDown() {
        let (operations, timer) = lock.withLock { () -> ([Operation], DispatchSourceTimer?) in
            let operations = [registration, browser].compactMap { $0 }
                + adverts.values.map(\.resolver)
            let timer = refreshTimer
            registration = nil
            browser = nil
            adverts = [:]
            refreshTimer = nil
            return (operations, timer)
        }
        timer?.cancel()
        operations.forEach(Self.release)
    }

    deinit {
        stop()
        session.invalidateAndCancel()
    }

    // MARK: DNS-SD callbacks (on `queue`)

    fileprivate func browsed(name: String, type: String, domain: String,
                             interfaceIndex: UInt32, added: Bool) {
        let key = AdvertKey(name: name, interfaceIndex: interfaceIndex)
        guard added else { return removeAdvert(key) }
        if lock.withLock({ adverts[key] != nil }) { return }
        var reference: DNSServiceRef?
        let error = DNSServiceResolve(
            &reference, 0, interfaceIndex, name, type, domain,
            appSyncResolveReply, Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let reference else { return }
        let resolver = Operation(reference: reference, source: monitor(reference))
        lock.withLock { adverts[key] = Advert(resolver: resolver, endpoint: nil) }
    }

    fileprivate func resolved(_ reference: DNSServiceRef, host: String, port: UInt16, txt: Data) {
        guard let expected = Self.txtValue("id", in: txt).flatMap(AppSyncPeerID.init),
              Self.txtValue("v", in: txt) == "1" else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/appsync/v1/registration"
        guard let url = components.url else { return }
        let endpoint = Endpoint(url: url, peerID: expected)
        lock.withLock {
            if let key = adverts.first(where: { $0.value.resolver.reference == reference })?.key {
                adverts[key]?.endpoint = endpoint
            }
        }
        fetch(endpoint)
    }

    // MARK: Presence

    private func removeAdvert(_ key: AdvertKey) {
        let removed: Advert? = lock.withLock {
            guard let advert = adverts.removeValue(forKey: key) else { return nil }
            // The same instance can be advertised on several interfaces; it
            // is gone only when none remain.
            if let peerID = advert.endpoint?.peerID,
               !adverts.values.contains(where: { $0.endpoint?.peerID == peerID }) {
                seen[peerID] = nil
            }
            return advert
        }
        if let removed { Self.release(removed.resolver) }
    }

    private func refresh() {
        let endpoints = lock.withLock { adverts.values.compactMap(\.endpoint) }
        var byPeer: [AppSyncPeerID: Endpoint] = [:]
        for endpoint in endpoints { byPeer[endpoint.peerID] = endpoint }
        byPeer.values.forEach(fetch)
    }

    private func fetch(_ endpoint: Endpoint) {
        let session = session
        Task { [weak self] in
            guard let (data, response) = try? await session.data(from: endpoint.url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let registration = try? JSONDecoder().decode(
                    AppSyncInstanceRegistration.self, from: data
                  ), registration.stablePeerID == endpoint.peerID,
                  (try? registration.verify()) != nil else { return }
            try? self?.observe(registration)
        }
    }

    // MARK: DNS-SD plumbing

    private func monitor(_ reference: DNSServiceRef) -> DispatchSourceRead? {
        let descriptor = DNSServiceRefSockFD(reference)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { _ = DNSServiceProcessResult(reference) }
        // The socket belongs to the reference; release it only once the
        // source can no longer read from it.
        source.setCancelHandler { DNSServiceRefDeallocate(reference) }
        source.resume()
        return source
    }

    private static func release(_ operation: Operation) {
        if let source = operation.source {
            source.cancel()
        } else {
            DNSServiceRefDeallocate(operation.reference)
        }
    }

    private static func txtRecord(peerID: AppSyncPeerID) -> Data {
        ["v=1", "id=\(peerID.rawValue)"].reduce(into: Data()) { data, value in
            let bytes = Data(value.utf8)
            data.append(UInt8(bytes.count)); data.append(bytes)
        }
    }

    private static func txtValue(_ key: String, in record: Data) -> String? {
        var index = record.startIndex
        while index < record.endIndex {
            let count = Int(record[index]); index = record.index(after: index)
            guard count <= record.distance(from: index, to: record.endIndex) else { return nil }
            let end = record.index(index, offsetBy: count)
            let field = String(decoding: record[index..<end], as: UTF8.self)
            index = end
            let pieces = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pieces.first == key { return pieces.count == 2 ? pieces[1] : "" }
        }
        return nil
    }
}

private func appSyncRegisterReply(
    _ sdRef: DNSServiceRef?, _ flags: DNSServiceFlags, _ errorCode: DNSServiceErrorType,
    _ name: UnsafePointer<CChar>?, _ regtype: UnsafePointer<CChar>?,
    _ domain: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {}

private func appSyncBrowseReply(
    _ sdRef: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?, _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError,
          let serviceName, let regtype, let replyDomain, let context else { return }
    Unmanaged<AppSyncLANDiscovery>.fromOpaque(context).takeUnretainedValue().browsed(
        name: String(cString: serviceName), type: String(cString: regtype),
        domain: String(cString: replyDomain), interfaceIndex: interfaceIndex,
        added: flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
    )
}

private func appSyncResolveReply(
    _ sdRef: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?, _ port: UInt16, _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?, _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError, let sdRef, let hosttarget, let context else { return }
    let txt = txtRecord.map { Data(bytes: $0, count: Int(txtLen)) } ?? Data()
    Unmanaged<AppSyncLANDiscovery>.fromOpaque(context).takeUnretainedValue().resolved(
        sdRef, host: String(cString: hosttarget), port: UInt16(bigEndian: port), txt: txt
    )
}
