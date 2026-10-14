import Foundation

public struct SpaceRecord: Codable, Hashable, Sendable {
    public let uri: String?
    public let cid: String
    public let collection: String
    public let rkey: String
    public let value: JSONValue?
}

public struct GetSpaceRecordOutput: Codable, Hashable, Sendable {
    public let uri: String
    public let cid: String
    public let value: JSONValue
}

public struct SpaceRecordList: Codable, Sendable {
    public let records: [SpaceRecord]
    public let cursor: String?
}

public struct PutSpaceRecordInput: Codable, Sendable {
    public let repo: String
    public let space: String
    public let collection: String
    public let rkey: String
    public let record: JSONValue
    public let validate: Bool

    public init(repo: DID, space: SpaceReference, collection: NSID, rkey: RecordKey,
                record: JSONValue, validate: Bool = true) {
        self.repo = repo.rawValue
        self.space = space.description
        self.collection = collection.rawValue
        self.rkey = rkey.rawValue
        self.record = record
        self.validate = validate
    }
}

public struct PutSpaceRecordOutput: Codable, Sendable { public let uri: String; public let cid: String }

public struct DeleteSpaceRecordInput: Codable, Sendable {
    public let repo: String
    public let space: String
    public let collection: String
    public let rkey: String

    public init(repo: DID, space: SpaceReference, collection: NSID, rkey: RecordKey) {
        self.repo = repo.rawValue
        self.space = space.description
        self.collection = collection.rawValue
        self.rkey = rkey.rawValue
    }
}

public struct CreateSimpleSpaceInput: Codable, Sendable {
    public let type: String
    public let skey: String
    public let readPolicy: JSONValue
    public let writePolicy: JSONValue
    public let appAccess: JSONValue

    public init(spaceType: NSID, key: RecordKey) {
        type = spaceType.rawValue
        skey = key.rawValue
        readPolicy = .object(["$type": .string("com.atproto.simplespace.defs#memberList")])
        writePolicy = .object(["$type": .string("com.atproto.simplespace.defs#memberList")])
        appAccess = .object(["$type": .string("com.atproto.simplespace.defs#open")])
    }
}

public struct CreateSimpleSpaceOutput: Codable, Sendable { public let uri: String }

public actor SpacesClient {
    public static let createSpace = NSID(rawValue: "com.atproto.simplespace.createSpace")!
    public static let getSpace = NSID(rawValue: "com.atproto.simplespace.getSpace")!
    public static let listRecords = NSID(rawValue: "com.atproto.space.listRecords")!
    public static let getRecord = NSID(rawValue: "com.atproto.space.getRecord")!
    public static let putRecord = NSID(rawValue: "com.atproto.space.putRecord")!
    public static let deleteRecord = NSID(rawValue: "com.atproto.space.deleteRecord")!

    private let xrpc: XRPCClient
    public init(xrpc: XRPCClient) { self.xrpc = xrpc }

    public func createOwnerSpace(type: NSID, key: RecordKey = RecordKey(rawValue: "self")!) async throws -> SpaceReference {
        let output: CreateSimpleSpaceOutput = try await xrpc.procedure(
            Self.createSpace, input: CreateSimpleSpaceInput(spaceType: type, key: key)
        )
        guard let space = SpaceReference(string: output.uri) else { throw URLError(.cannotParseResponse) }
        return space
    }

    public func listRecords(space: SpaceReference, repo: DID, collection: NSID? = nil,
                            cursor: String? = nil, limit: Int = 100) async throws -> SpaceRecordList {
        var query = [URLQueryItem(name: "space", value: space.description),
                     URLQueryItem(name: "repo", value: repo.rawValue),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let collection { query.append(.init(name: "collection", value: collection.rawValue)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await xrpc.query(Self.listRecords, parameters: query)
    }

    public func putRecord(_ input: PutSpaceRecordInput) async throws -> PutSpaceRecordOutput {
        try await xrpc.procedure(Self.putRecord, input: input)
    }

    public func getRecord(space: SpaceReference, repo: DID, collection: NSID,
                          rkey: RecordKey) async throws -> GetSpaceRecordOutput {
        try await xrpc.query(Self.getRecord, parameters: [
            .init(name: "space", value: space.description),
            .init(name: "repo", value: repo.rawValue),
            .init(name: "collection", value: collection.rawValue),
            .init(name: "rkey", value: rkey.rawValue),
        ])
    }

    public func deleteRecord(_ input: DeleteSpaceRecordInput) async throws {
        try await xrpc.procedure(Self.deleteRecord, input: input)
    }
}
