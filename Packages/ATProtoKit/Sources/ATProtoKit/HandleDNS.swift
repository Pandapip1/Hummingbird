import Foundation
#if canImport(dnssd)
import dnssd
#elseif canImport(CATProtoResolv)
import CATProtoResolv
#endif

/// Looks up DNS TXT records. Injected into ``ATProtoIdentityResolver`` so
/// tests can resolve handles without a network.
public protocol DNSTXTResolving: Sendable {
    /// The value of each TXT record at `name`, its character-strings joined.
    /// Returns an empty array when the name or the record does not exist, and
    /// throws when the lookup itself failed.
    func txtRecords(for name: String) async throws -> [String]
}

public enum DNSTXTError: Error, Sendable {
    case lookupFailed(String)
    case timedOut
}

enum DNSTXT {
    /// Joins the length-prefixed character-strings of one TXT record's RDATA.
    /// Returns nil when a length runs past the end, or the text isn't UTF-8.
    static func value(ofRData rdata: some Collection<UInt8>) -> String? {
        var bytes: [UInt8] = []
        var index = rdata.startIndex
        while index != rdata.endIndex {
            let length = Int(rdata[index])
            index = rdata.index(after: index)
            guard let end = rdata.index(index, offsetBy: length, limitedBy: rdata.endIndex) else { return nil }
            bytes.append(contentsOf: rdata[index..<end])
            index = end
        }
        return String(validating: bytes, as: UTF8.self)
    }
}

/// The platform's own resolver, so system DNS settings (VPN, split DNS,
/// resolv.conf) apply. Apple platforms use dnssd, served by mDNSResponder,
/// which performs unicast queries for ordinary domains. Linux uses
/// libresolv: avahi's dns_sd compatibility layer only speaks multicast DNS
/// and cannot look up public TXT records.
public struct SystemDNSTXTResolver: DNSTXTResolving {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) { self.timeout = timeout }

    public func txtRecords(for name: String) async throws -> [String] {
        let timeout = timeout
        // Both platform APIs block their calling thread while waiting for
        // the answer, so keep them off the cooperative thread pool.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.query(name, timeout: timeout) })
            }
        }
    }

    #if canImport(dnssd)
    /// Answers accumulated by the dnssd callback. Only touched on the thread
    /// running `query`: `DNSServiceProcessResult` calls back synchronously.
    private final class Answers {
        var records: [String] = []
        var error = DNSServiceErrorType(kDNSServiceErr_NoError)
        var finished = false
    }

    private static func query(_ name: String, timeout: Duration) throws -> [String] {
        let answers = Answers()
        let context = Unmanaged.passUnretained(answers).toOpaque()
        var reference: DNSServiceRef?
        // Intermediates deliver a negative answer as NoSuchRecord instead of
        // waiting forever for a record that does not exist.
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let started = DNSServiceQueryRecord(
            &reference, flags, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
            { _, flags, _, error, _, _, _, length, rdata, _, context in
                guard let context else { return }
                let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
                if error != kDNSServiceErr_NoError {
                    answers.error = error
                    answers.finished = true
                    return
                }
                if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let rdata,
                   let value = DNSTXT.value(ofRData: UnsafeRawBufferPointer(start: rdata, count: Int(length))) {
                    answers.records.append(value)
                }
                if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { answers.finished = true }
            },
            context
        )
        guard started == kDNSServiceErr_NoError, let reference else {
            throw DNSTXTError.lookupFailed("DNSServiceQueryRecord error \(started)")
        }
        defer { DNSServiceRefDeallocate(reference) }
        return try withExtendedLifetime(answers) {
            let deadline = ContinuousClock.now + timeout
            var descriptor = pollfd(fd: DNSServiceRefSockFD(reference), events: Int16(POLLIN), revents: 0)
            while !answers.finished {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw DNSTXTError.timedOut }
                let milliseconds = Int32(clamping: remaining.components.seconds * 1_000
                    + remaining.components.attoseconds / 1_000_000_000_000_000 + 1)
                let ready = poll(&descriptor, 1, milliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw DNSTXTError.lookupFailed("poll failed: errno \(errno)")
                }
                if ready == 0 { throw DNSTXTError.timedOut }
                let processed = DNSServiceProcessResult(reference)
                guard processed == kDNSServiceErr_NoError else {
                    throw DNSTXTError.lookupFailed("DNSServiceProcessResult error \(processed)")
                }
            }
            switch Int(answers.error) {
            case kDNSServiceErr_NoError: return answers.records
            case kDNSServiceErr_NoSuchRecord, kDNSServiceErr_NoSuchName: return []
            default: throw DNSTXTError.lookupFailed("DNS error \(answers.error)")
            }
        }
    }
    #elseif canImport(CATProtoResolv)
    private final class Answers {
        var records: [String] = []
    }

    private static func query(_ name: String, timeout: Duration) throws -> [String] {
        // libresolv applies its own configured timeout and retry policy
        // (resolv.conf `options timeout:`/`attempts:`).
        _ = timeout
        let answers = Answers()
        let status = withExtendedLifetime(answers) {
            atproto_resolv_query_txt(name, { rdata, length, context in
                guard let rdata, let context else { return }
                let answers = Unmanaged<Answers>.fromOpaque(context).takeUnretainedValue()
                if let value = DNSTXT.value(ofRData: UnsafeBufferPointer(start: rdata, count: length)) {
                    answers.records.append(value)
                }
            }, Unmanaged.passUnretained(answers).toOpaque())
        }
        guard status == 0 else { throw DNSTXTError.lookupFailed("libresolv could not query \(name)") }
        return answers.records
    }
    #else
    private static func query(_ name: String, timeout: Duration) throws -> [String] {
        throw DNSTXTError.lookupFailed("DNS TXT lookup is not available on this platform.")
    }
    #endif
}
