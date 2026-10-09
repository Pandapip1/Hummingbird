import Foundation

enum UMPProtocolError: Error, Equatable {
    case truncated, malformed, oversized, unsupportedWireType(Int), invalidFormat
}

struct ProtoWriter {
    private(set) var data = Data()
    mutating func varint(_ field: Int, _ value: UInt64) { key(field, 0); rawVarint(value) }
    mutating func sint(_ field: Int, _ value: Int64) { varint(field, UInt64(bitPattern: value)) }
    mutating func bytes(_ field: Int, _ value: Data) { key(field, 2); rawVarint(UInt64(value.count)); data.append(value) }
    mutating func string(_ field: Int, _ value: String?) { if let value, !value.isEmpty { bytes(field, Data(value.utf8)) } }
    mutating func message(_ field: Int, _ body: (inout ProtoWriter) -> Void) { var child = ProtoWriter(); body(&child); bytes(field, child.data) }
    mutating func fixed32(_ field: Int, _ value: UInt32) { key(field, 5); withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    private mutating func key(_ field: Int, _ wire: UInt64) { rawVarint(UInt64(field) << 3 | wire) }
    mutating func rawVarint(_ value: UInt64) { var v = value; while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }; data.append(UInt8(v)) }
}

struct ProtoField { let number: Int; let wire: Int; let varint: UInt64?; let bytes: Data? }

struct ProtoReader {
    // Data slices retain their original indices. Protocol payloads are often
    // slices of a framed response, so rebase them before offset-based parsing.
    private let data: [UInt8]
    init(_ data: Data) { self.data = Array(data) }
    func fields(maxBytes: Int = 32 * 1024 * 1024) throws -> [ProtoField] {
        guard data.count <= maxBytes else { throw UMPProtocolError.oversized }
        var offset = 0, result: [ProtoField] = []
        while offset < data.count {
            let key = try Self.varint(data, &offset); let number = Int(key >> 3), wire = Int(key & 7)
            guard number > 0 else { throw UMPProtocolError.malformed }
            switch wire {
            case 0: result.append(.init(number: number, wire: wire, varint: try Self.varint(data, &offset), bytes: nil))
            case 1: guard offset + 8 <= data.count else { throw UMPProtocolError.truncated }; result.append(.init(number: number, wire: wire, varint: nil, bytes: Data(data[offset..<offset+8]))); offset += 8
            case 2:
                let length = try Self.varint(data, &offset); guard length <= UInt64(maxBytes), length <= UInt64(data.count - offset) else { throw UMPProtocolError.truncated }
                let end = offset + Int(length); result.append(.init(number: number, wire: wire, varint: nil, bytes: Data(data[offset..<end]))); offset = end
            case 5: guard offset + 4 <= data.count else { throw UMPProtocolError.truncated }; result.append(.init(number: number, wire: wire, varint: nil, bytes: Data(data[offset..<offset+4]))); offset += 4
            default: throw UMPProtocolError.unsupportedWireType(wire)
            }
        }
        return result
    }
    static func varint(_ data: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        for _ in 0..<10 { guard offset < data.count else { throw UMPProtocolError.truncated }; let b = data[offset]; offset += 1; value |= UInt64(b & 0x7f) << shift; if b < 0x80 { return value }; shift += 7 }
        throw UMPProtocolError.malformed
    }
}

struct UMPPart: Equatable { let type: UInt64; let payload: Data }

enum UMPFraming {
    static func encodeCompact(_ value: UInt64) throws -> Data {
        if value < 0x80 { return Data([UInt8(value)]) }
        if value < 0x4000 { return Data([0x80 | UInt8(value & 0x3f), UInt8((value >> 6) & 0xff)]) }
        if value < 0x20_0000 { return Data([0xc0 | UInt8(value & 0x1f), UInt8((value >> 5) & 0xff), UInt8((value >> 13) & 0xff)]) }
        if value < 0x1000_0000 { return Data([0xe0 | UInt8(value & 0x0f), UInt8((value >> 4) & 0xff), UInt8((value >> 12) & 0xff), UInt8((value >> 20) & 0xff)]) }
        guard value <= UInt64(UInt32.max) else { throw UMPProtocolError.oversized }
        var out = Data([0xf0]); var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }; return out
    }
    static func decodeCompact(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        guard offset < data.count else { throw UMPProtocolError.truncated }; let first = data[offset]; offset += 1
        if first < 0x80 { return UInt64(first) }
        let count: Int, low: UInt64, bits: Int
        if first < 0xc0 { count = 1; low = UInt64(first & 0x3f); bits = 6 }
        else if first < 0xe0 { count = 2; low = UInt64(first & 0x1f); bits = 5 }
        else if first < 0xf0 { count = 3; low = UInt64(first & 0x0f); bits = 4 }
        else { count = 4; low = 0; bits = 0 }
        guard offset + count <= data.count else { throw UMPProtocolError.truncated }
        var result = low
        for i in 0..<count { result |= UInt64(data[offset + i]) << UInt64(bits + i * 8) }
        offset += count; return result
    }
    static func decode(_ data: Data, maximumPartSize: Int = 32 * 1024 * 1024) throws -> [UMPPart] {
        var offset = 0, parts: [UMPPart] = []
        while offset < data.count { let type = try decodeCompact(data, &offset); let size = try decodeCompact(data, &offset); guard size <= UInt64(maximumPartSize), size <= UInt64(data.count - offset) else { throw UMPProtocolError.truncated }; let end = offset + Int(size); parts.append(.init(type: type, payload: Data(data[offset..<end]))); offset = end }
        return parts
    }
}

struct UMPFormatID: Hashable {
    let itag: Int; let lastModified: UInt64; let xtags: String?
    init(_ format: UMPFormat) { itag = format.itag; lastModified = format.lastModified; xtags = format.xtags }
    init(data: Data) throws {
        let f = try ProtoReader(data).fields(); itag = Int(f.first { $0.number == 1 }?.varint ?? 0); lastModified = f.first { $0.number == 2 }?.varint ?? 0; xtags = f.first { $0.number == 3 }?.bytes.flatMap { String(data: $0, encoding: .utf8) }
    }
    func encode() -> Data { var w = ProtoWriter(); w.varint(1, UInt64(itag)); w.varint(2, lastModified); w.string(3, xtags); return w.data }
}

struct UMPTimeRange { let start: Int64; let duration: Int64; let timescale: Int64 }
struct UMPMediaHeader {
    let id: UInt64; let format: UMPFormatID; let isInit: Bool; let sequence: Int; let startMS: Int64; let durationMS: Int64; let expectedLength: Int?; let tickRange: UMPTimeRange?
    init(_ data: Data) throws {
        let f = try ProtoReader(data).fields(); id = f.first { $0.number == 1 }?.varint ?? 0
        guard let itag = f.first(where: { $0.number == 3 })?.varint, let modified = f.first(where: { $0.number == 4 })?.varint else { throw UMPProtocolError.invalidFormat }
        let xtags = f.first { $0.number == 5 }?.bytes.flatMap { String(data: $0, encoding: .utf8) }; format = UMPFormatID(rawItag: Int(itag), lastModified: modified, xtags: xtags)
        isInit = (f.first { $0.number == 8 }?.varint ?? 0) != 0; sequence = Int(f.first { $0.number == 9 }?.varint ?? 0)
        startMS = Int64(bitPattern: f.first { $0.number == 11 }?.varint ?? 0); durationMS = Int64(bitPattern: f.first { $0.number == 12 }?.varint ?? 0)
        expectedLength = f.first { $0.number == 14 }?.varint.map { Int($0) }
        if let b = f.first(where: { $0.number == 15 })?.bytes { let t = try ProtoReader(b).fields(); tickRange = .init(start: Int64(bitPattern: t.first { $0.number == 1 }?.varint ?? 0), duration: Int64(bitPattern: t.first { $0.number == 2 }?.varint ?? 0), timescale: Int64(bitPattern: t.first { $0.number == 3 }?.varint ?? 0)) } else { tickRange = nil }
    }
}

extension UMPFormatID { fileprivate init(rawItag: Int, lastModified: UInt64, xtags: String?) { self.itag = rawItag; self.lastModified = lastModified; self.xtags = xtags } }

struct UMPInitMetadata {
    let format: UMPFormatID; let mediaEndMS: Int64; let finalSegment: Int; let mimeType: String
    init(_ data: Data) throws { let f = try ProtoReader(data).fields(); guard let id = f.first(where: { $0.number == 2 })?.bytes else { throw UMPProtocolError.invalidFormat }; format = try UMPFormatID(data: id); mediaEndMS = Int64(bitPattern: f.first { $0.number == 3 }?.varint ?? 0); finalSegment = Int(f.first { $0.number == 4 }?.varint ?? 0); mimeType = f.first { $0.number == 5 }?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "application/octet-stream" }
}

struct UMPMediaChunk: Sendable { let sequence: Int; let start: Double; let duration: Double; let data: Data }
struct UMPTrackResult { let format: UMPFormat; let initialization: Data; let segments: [UMPMediaChunk] }
