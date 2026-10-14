import Foundation

public struct DID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("did:"), rawValue.utf8.count <= 2_048,
              !rawValue.contains(where: { $0.isWhitespace }) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct NSID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let labels = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, rawValue.utf8.count <= 317,
              labels.allSatisfy(Self.validLabel) else { return nil }
        self.rawValue = rawValue
    }

    private static func validLabel(_ label: Substring) -> Bool {
        guard let first = label.utf8.first, Self.isLetter(first), label.utf8.count <= 63 else { return false }
        return label.utf8.allSatisfy { isLetter($0) || (48...57).contains($0) || $0 == 45 }
            && label.utf8.last != 45
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    public var description: String { rawValue }
}

public struct RecordKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 512,
              rawValue.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || [46, 45, 58, 95, 126].contains(byte)
              }), rawValue != ".", rawValue != ".." else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct SpaceReference: Codable, Hashable, Sendable, CustomStringConvertible {
    public let authority: DID
    public let type: NSID
    public let key: RecordKey

    public init(authority: DID, type: NSID, key: RecordKey) {
        self.authority = authority
        self.type = type
        self.key = key
    }

    public init?(string: String) {
        guard string.hasPrefix("at://") else { return nil }
        let components = String(string.dropFirst(5)).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4, components[1] == "space",
              let authority = DID(rawValue: String(components[0])),
              let type = NSID(rawValue: String(components[2])),
              let key = RecordKey(rawValue: String(components[3])) else { return nil }
        self.init(authority: authority, type: type, key: key)
    }

    public var description: String { "at://\(authority)/space/\(type)/\(key)" }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .double(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .integer(let integer): try value.encode(integer)
        case .double(let double): try value.encode(double)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public extension JSONValue {
    static func encoding<Value: Encodable>(_ value: Value, encoder: JSONEncoder = JSONEncoder()) throws -> Self {
        try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }

    func decode<Value: Decodable>(_ type: Value.Type, decoder: JSONDecoder = JSONDecoder()) throws -> Value {
        try decoder.decode(type, from: JSONEncoder().encode(self))
    }
}
