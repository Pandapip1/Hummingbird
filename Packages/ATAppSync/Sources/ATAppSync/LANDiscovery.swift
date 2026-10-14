import CDNSService
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Standard DNS-SD presence for AppSync instances. DNS-SD only supplies a
/// routable HTTP endpoint and expected key digest; the signed registration at
/// that endpoint remains the authority for identity, capabilities, and apps.
final class AppSyncLANDiscovery: @unchecked Sendable {
    private static let serviceType = "_atproto-appsync._tcp"
    private static let lifetime: TimeInterval = 90

    private struct Seen {
        let registration: AppSyncInstanceRegistration
        let receivedAt: Date
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.eightybps.appsync.dnssd")
    private var registrationRef: DNSServiceRef?
    private var browseRef: DNSServiceRef?
    private var resolveRefs: [DNSServiceRef] = []
    private var sources: [DispatchSourceRead] = []
    private var seen: [AppSyncPeerID: Seen] = [:]

    func start(advertising registration: AppSyncInstanceRegistration) async throws {
        try registration.verify()
        guard let endpoint = registration.lanEndpoint,
              let port = endpoint.port, (1...Int(UInt16.max)).contains(port) else {
            throw InstanceMessagingError.serverUnavailable
        }
        if lock.withLock({ registrationRef != nil }) { return }

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
            throw InstanceMessagingError.serverUnavailable
        }

        var browseRef: DNSServiceRef?
        let browseError = DNSServiceBrowse(
            &browseRef, 0, 0, Self.serviceType, nil, appSyncBrowseReply, context
        )
        guard browseError == kDNSServiceErr_NoError, let browseRef else {
            DNSServiceRefDeallocate(registerRef)
            throw InstanceMessagingError.serverUnavailable
        }
        lock.withLock {
            self.registrationRef = registerRef
            self.browseRef = browseRef
        }
        monitor(registerRef)
        monitor(browseRef)
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

    func stop() {
        let state = lock.withLock { () -> ([DispatchSourceRead], [DNSServiceRef]) in
            let refs = [registrationRef, browseRef].compactMap { $0 } + resolveRefs
            let result = (sources, refs)
            sources = []
            resolveRefs = []
            registrationRef = nil
            browseRef = nil
            return result
        }
        state.0.forEach { $0.cancel() }
        state.1.forEach(DNSServiceRefDeallocate)
    }

    deinit { stop() }

    fileprivate func resolve(name: String, type: String, domain: String,
                             interfaceIndex: UInt32) {
        var reference: DNSServiceRef?
        let error = DNSServiceResolve(
            &reference, 0, interfaceIndex, name, type, domain,
            appSyncResolveReply, Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let reference else { return }
        lock.withLock { resolveRefs.append(reference) }
        monitor(reference)
    }

    fileprivate func found(host: String, port: UInt16, txt: Data) {
        guard let expected = Self.txtValue("id", in: txt).flatMap(AppSyncPeerID.init),
              Self.txtValue("v", in: txt) == "1" else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = "/appsync/v1/registration"
        guard let url = components.url else { return }
        Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let registration = try? JSONDecoder().decode(
                    AppSyncInstanceRegistration.self, from: data
                  ), registration.stablePeerID == expected,
                  (try? registration.verify()) != nil else { return }
            try? self?.observe(registration)
        }
    }

    private func monitor(_ reference: DNSServiceRef) {
        let descriptor = DNSServiceRefSockFD(reference)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { _ = DNSServiceProcessResult(reference) }
        source.resume()
        lock.withLock { sources.append(source) }
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
          flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
          let serviceName, let regtype, let replyDomain, let context else { return }
    Unmanaged<AppSyncLANDiscovery>.fromOpaque(context).takeUnretainedValue().resolve(
        name: String(cString: serviceName), type: String(cString: regtype),
        domain: String(cString: replyDomain), interfaceIndex: interfaceIndex
    )
}

private func appSyncResolveReply(
    _ sdRef: DNSServiceRef?, _ flags: DNSServiceFlags, _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType, _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?, _ port: UInt16, _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?, _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError, let hosttarget, let context else { return }
    let txt = txtRecord.map { Data(bytes: $0, count: Int(txtLen)) } ?? Data()
    Unmanaged<AppSyncLANDiscovery>.fromOpaque(context).takeUnretainedValue().found(
        host: String(cString: hosttarget), port: UInt16(bigEndian: port), txt: txt
    )
}
