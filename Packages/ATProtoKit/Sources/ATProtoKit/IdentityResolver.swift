import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResolvedIdentity: Hashable, Sendable {
    public let did: DID
    public let handle: String?
    public let pds: URL
}

public actor ATProtoIdentityResolver {
    /// Fetches a URL. Injected so tests can serve documents without a network.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let dns: any DNSTXTResolving
    private let plcDirectory: URL

    public init(session: URLSession = .shared,
                plcDirectory: URL = URL(string: "https://plc.directory")!,
                dns: any DNSTXTResolving = SystemDNSTXTResolver()) {
        self.init(plcDirectory: plcDirectory, dns: dns, fetch: { try await session.data(from: $0) })
    }

    public init(plcDirectory: URL = URL(string: "https://plc.directory")!,
                dns: any DNSTXTResolving, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.dns = dns
        self.plcDirectory = plcDirectory
    }

    public func resolve(_ identifier: String) async throws -> ResolvedIdentity {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let did: DID
        let handle: String?
        let document: DIDDocument
        if let parsed = DID(rawValue: trimmed) {
            did = parsed
            handle = nil
            document = try await didDocument(did)
        } else {
            let normalized = Self.normalizedHandle(trimmed)
            guard Self.isValidHandle(normalized) else { throw OAuthError.invalidIdentifier }
            did = try await resolveHandle(normalized)
            document = try await didDocument(did)
            // A handle is only an account's if the account claims it back:
            // anyone can point their own domain's record at someone's DID.
            guard document.claims(handle: normalized) else {
                throw OAuthError.handleNotVerified("\(normalized) is not claimed by the account \(did.rawValue).")
            }
            handle = normalized
        }
        guard let endpoint = document.service?.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let pds = URL(string: endpoint), pds.scheme == "https" else {
            throw OAuthError.invalidMetadata("DID document has no HTTPS #atproto_pds service.")
        }
        return ResolvedIdentity(did: did, handle: handle, pds: pds)
    }

    /// The DID a handle points to, through DNS (`_atproto.<handle>` TXT) and
    /// then HTTPS (`/.well-known/atproto-did`). Either method may hold the
    /// record, so a failure of one falls through to the other.
    func resolveHandle(_ handle: String) async throws -> DID {
        var dnsFailure: (any Error)?
        do {
            if let did = try Self.did(fromTXT: await dns.txtRecords(for: "_atproto.\(handle)")) { return did }
        } catch {
            dnsFailure = error
        }
        do {
            guard let url = URL(string: "https://\(handle)/.well-known/atproto-did") else {
                throw OAuthError.invalidIdentifier
            }
            let (data, response) = try await fetch(url)
            try Self.requireSuccess(response)
            guard let did = Self.did(fromWellKnown: data) else {
                throw OAuthError.invalidMetadata("no DID in /.well-known/atproto-did")
            }
            return did
        } catch {
            throw OAuthError.handleNotResolved(
                HandleResolutionFailure(handle: handle, dnsFailure: dnsFailure, httpsFailure: error)
            )
        }
    }

    /// The DID named by `_atproto` TXT records. Records not starting with
    /// `did=` are ignored. Several records naming different DIDs are
    /// ambiguous, so the DNS method then fails rather than pick one.
    static func did(fromTXT records: [String]) throws -> DID? {
        let dids = Set(records.compactMap { record -> DID? in
            guard record.hasPrefix("did=") else { return nil }
            return DID(rawValue: String(record.dropFirst("did=".count)))
        })
        guard dids.count <= 1 else {
            throw OAuthError.handleNotVerified("its _atproto DNS records name different accounts")
        }
        return dids.first
    }

    static func did(fromWellKnown data: Data) -> DID? {
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return DID(rawValue: value)
    }

    /// A handle as typed, in canonical form: handles are case-insensitive and
    /// are often written with a leading "@", which isn't part of the handle.
    static func normalizedHandle(_ input: String) -> String {
        var handle = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if handle.hasPrefix("@") { handle.removeFirst() }
        return handle
    }

    /// The atproto handle syntax: at least two DNS labels of ASCII letters,
    /// digits and inner hyphens, at most 253 characters, with a final label
    /// that does not start with a digit. This also keeps the handle from
    /// reshaping the DNS name or URL it is substituted into.
    static func isValidHandle(_ handle: String) -> Bool {
        guard handle.utf8.count <= 253 else { return false }
        let labels = handle.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ byte in
                      byte == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                          || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                  }) else { return false }
        }
        return labels.last?.first?.isLetter == true
    }

    private func didDocument(_ did: DID) async throws -> DIDDocument {
        let url: URL
        if did.rawValue.hasPrefix("did:plc:") {
            url = plcDirectory.appendingPathComponent(did.rawValue)
        } else if did.rawValue.hasPrefix("did:web:") {
            let method = String(did.rawValue.dropFirst("did:web:".count))
            let components = method.split(separator: ":").map(String.init)
            guard let host = components.first else { throw OAuthError.invalidIdentifier }
            var builder = URLComponents()
            builder.scheme = "https"
            builder.host = host.removingPercentEncoding ?? host
            builder.path = components.count == 1
                ? "/.well-known/did.json"
                : "/" + components.dropFirst().joined(separator: "/") + "/did.json"
            guard let built = builder.url else { throw OAuthError.invalidIdentifier }
            url = built
        } else {
            throw OAuthError.invalidIdentifier
        }
        let (data, response) = try await fetch(url)
        try Self.requireSuccess(response)
        let document = try JSONDecoder().decode(DIDDocument.self, from: data)
        guard document.id == did.rawValue else { throw OAuthError.invalidMetadata("DID document id mismatch.") }
        return document
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(status) from \(response.url?.host ?? "server")",
            ])
        }
    }
}

struct DIDDocument: Decodable {
    struct Service: Decodable {
        let id: String
        let serviceEndpoint: String
    }
    let id: String
    let alsoKnownAs: [String]?
    let service: [Service]?

    /// Whether the document lists `at://<handle>`. Handles compare
    /// case-insensitively; `handle` is already normalized to lowercase.
    func claims(handle: String) -> Bool {
        (alsoKnownAs ?? []).contains { $0.lowercased() == "at://\(handle)" }
    }
}
