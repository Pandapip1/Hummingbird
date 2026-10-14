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
    private let session: URLSession
    private let plcDirectory: URL

    public init(session: URLSession = .shared,
                plcDirectory: URL = URL(string: "https://plc.directory")!) {
        self.session = session
        self.plcDirectory = plcDirectory
    }

    public func resolve(_ identifier: String) async throws -> ResolvedIdentity {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let did: DID
        let handle: String?
        if let parsed = DID(rawValue: trimmed) {
            did = parsed
            handle = nil
        } else {
            let normalized = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard normalized.contains("."),
                  let url = URL(string: "https://\(normalized)/.well-known/atproto-did") else {
                throw OAuthError.invalidIdentifier
            }
            let (data, response) = try await session.data(from: url)
            try Self.requireSuccess(response)
            guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = DID(rawValue: value) else { throw OAuthError.invalidIdentifier }
            did = parsed
            handle = normalized
        }
        let document = try await didDocument(did)
        guard let endpoint = document.service.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let pds = URL(string: endpoint), pds.scheme == "https" else {
            throw OAuthError.invalidMetadata("DID document has no HTTPS #atproto_pds service.")
        }
        return ResolvedIdentity(did: did, handle: handle, pds: pds)
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
        let (data, response) = try await session.data(from: url)
        try Self.requireSuccess(response)
        let document = try JSONDecoder().decode(DIDDocument.self, from: data)
        guard document.id == did.rawValue else { throw OAuthError.invalidMetadata("DID document id mismatch.") }
        return document
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

private struct DIDDocument: Decodable {
    struct Service: Decodable {
        let id: String
        let serviceEndpoint: String
    }
    let id: String
    let service: [Service]
}
