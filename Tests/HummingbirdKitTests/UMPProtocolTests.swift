import XCTest
@testable import HummingbirdKit

final class UMPProtocolTests: XCTestCase {
    func testCompactIntegerBoundariesRoundTrip() throws {
        for value: UInt64 in [0, 0x7f, 0x80, 0x3fff, 0x4000, 0x1f_ffff, 0x20_0000, 0x0fff_ffff, 0x1000_0000, UInt64(UInt32.max)] {
            let encoded = try UMPFraming.encodeCompact(value)
            var offset = 0
            XCTAssertEqual(try UMPFraming.decodeCompact(encoded, &offset), value)
            XCTAssertEqual(offset, encoded.count)
        }
    }

    func testFramingRejectsTruncation() throws {
        let type = try UMPFraming.encodeCompact(20)
        let length = try UMPFraming.encodeCompact(5)
        XCTAssertThrowsError(try UMPFraming.decode(type + length + Data([1, 2])))
    }

    func testProtobufSkipsKnownWireShapes() throws {
        var writer = ProtoWriter()
        writer.varint(1, 150)
        writer.bytes(2, Data("abc".utf8))
        writer.fixed32(3, 0x12345678)
        let fields = try ProtoReader(writer.data).fields()
        XCTAssertEqual(fields.map(\.number), [1, 2, 3])
        XCTAssertEqual(fields[0].varint, 150)
        XCTAssertEqual(fields[1].bytes, Data("abc".utf8))
    }

    func testUMPSourceDecodesAndIsSelectable() throws {
        let json = #"{"contentType":1,"name":"Example","url":"https://example.com/watch","video":{"isUnMuxed":false,"videoSources":[{"plugin_type":"UMPSource","url":"https://example.com/ump","ustreamerConfig":"AQ","videoFormats":[{"itag":137,"lastModified":"18446744073709551615","mimeType":"video/mp4","height":1080}],"audioFormats":[{"itag":140,"lastModified":"7","mimeType":"audio/mp4"}]}]}}"#
        let details = try JSONDecoder().decode(VideoDetails.self, from: Data(json.utf8))
        let source = try XCTUnwrap(details.videoSources.first)
        XCTAssertEqual(source.videoFormats.first?.lastModified, UInt64.max)
        XCTAssertTrue(source.isUMP)
        XCTAssertEqual(PlaybackSelector.options(for: details).first?.kind, .ump)
    }
}
