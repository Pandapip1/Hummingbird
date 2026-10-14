import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct XRPCError: LocalizedError, Sendable {
    public let statusCode: Int
    public let error: String?
    public let message: String?

    public var errorDescription: String? {
        message ?? error ?? "AT Protocol request failed with HTTP \(statusCode)."
    }
}

public struct XRPCRequest: Sendable {
    public enum Method: String, Sendable { case GET, POST }
    public var method: Method
    public var nsid: NSID
    public var query: [URLQueryItem]
    public var body: Data?

    public init(method: Method, nsid: NSID, query: [URLQueryItem] = [], body: Data? = nil) {
        self.method = method
        self.nsid = nsid
        self.query = query
        self.body = body
    }
}

public protocol ATProtoAuthorizationProvider: Sendable {
    func authorize(_ request: URLRequest) async throws -> URLRequest
    func didReceive(_ response: HTTPURLResponse, data: Data, for request: URLRequest) async throws -> Bool
}

public extension ATProtoAuthorizationProvider {
    func didReceive(_ response: HTTPURLResponse, data: Data, for request: URLRequest) async throws -> Bool { false }
}

public struct BearerAuthorization: ATProtoAuthorizationProvider {
    public let token: @Sendable () async throws -> String
    public init(token: @escaping @Sendable () async throws -> String) { self.token = token }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        return request
    }
}

public actor XRPCClient {
    private let service: URL
    private let session: URLSession
    private let authorization: (any ATProtoAuthorizationProvider)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(service: URL, session: URLSession = .shared,
                authorization: (any ATProtoAuthorizationProvider)? = nil) {
        self.service = service
        self.session = session
        self.authorization = authorization
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func query<Response: Decodable & Sendable>(
        _ nsid: NSID, parameters: [URLQueryItem] = [], as type: Response.Type = Response.self
    ) async throws -> Response {
        try await send(.init(method: .GET, nsid: nsid, query: parameters), as: type)
    }

    public func procedure<Input: Encodable & Sendable, Response: Decodable & Sendable>(
        _ nsid: NSID, input: Input, as type: Response.Type = Response.self
    ) async throws -> Response {
        try await send(.init(method: .POST, nsid: nsid, body: try encoder.encode(input)), as: type)
    }

    public func procedure<Input: Encodable & Sendable>(_ nsid: NSID, input: Input) async throws {
        let _: EmptyResponse = try await procedure(nsid, input: input)
    }

    private func send<Response: Decodable & Sendable>(
        _ xrpc: XRPCRequest, as type: Response.Type
    ) async throws -> Response {
        var components = URLComponents(url: service, resolvingAgainstBaseURL: false)!
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/xrpc/" + xrpc.nsid.rawValue
        components.queryItems = xrpc.query.isEmpty ? nil : xrpc.query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = xrpc.method.rawValue
        request.httpBody = xrpc.body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if xrpc.body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let authorization { request = try await authorization.authorize(request) }
        var (data, response) = try await session.data(for: request)
        if let authorization, let http = response as? HTTPURLResponse,
           try await authorization.didReceive(http, data: data, for: request) {
            request = try await authorization.authorize(request)
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? decoder.decode(ErrorBody.self, from: data)
            throw XRPCError(statusCode: http.statusCode, error: body?.error, message: body?.message)
        }
        if Response.self == EmptyResponse.self, data.isEmpty { return EmptyResponse() as! Response }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct ErrorBody: Decodable { let error: String?; let message: String? }
public struct EmptyResponse: Codable, Sendable { public init() {} }
