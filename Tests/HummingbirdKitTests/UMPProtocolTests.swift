import XCTest
@testable import HummingbirdKit

final class UMPProtocolTests: XCTestCase {
    func testOnlyRefreshableSessionFailuresTriggerPlaybackRecovery() {
        XCTAssertTrue(UMPSessionError.reloadRequired.isRefreshRequired)
        XCTAssertTrue(UMPSessionError.protectionExpired.isRefreshRequired)
        XCTAssertFalse(UMPSessionError.noProgress.isRefreshRequired)
        XCTAssertFalse(UMPSessionError.incomplete.isRefreshRequired)
    }

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

    func testProtobufReaderRebasesDataSlices() throws {
        var writer = ProtoWriter()
        writer.varint(1, 150)
        writer.bytes(2, Data("abc".utf8))
        let framed = Data([0xde, 0xad]) + writer.data + Data([0xbe, 0xef])
        let slice = framed[2..<(framed.count - 2)]
        XCTAssertNotEqual(slice.startIndex, 0)

        let fields = try ProtoReader(slice).fields()
        XCTAssertEqual(fields[0].varint, 150)
        XCTAssertEqual(fields[1].bytes, Data("abc".utf8))
    }

    func testRepeatedVarintsAcceptPackedAndUnpackedEncodings() throws {
        var packedValues = ProtoWriter()
        packedValues.rawVarint(2)
        packedValues.rawVarint(127)
        packedValues.rawVarint(16_384)

        var writer = ProtoWriter()
        writer.varint(1, 1)
        writer.bytes(1, packedValues.data)
        writer.varint(1, 65_535)

        let values = try ProtoReader(writer.data).fields().flatMap { try $0.repeatedVarints() }
        XCTAssertEqual(values, [1, 2, 127, 16_384, 65_535])
    }

    func testPackedRepeatedVarintsRejectTruncation() throws {
        let field = ProtoField(number: 1, wire: 2, varint: nil, bytes: Data([0x80]))
        XCTAssertThrowsError(try field.repeatedVarints())
    }

    func testUMPSourceDecodesAndIsSelectable() throws {
        let json = #"{"contentType":1,"name":"Example","url":"https://example.com/watch","video":{"isUnMuxed":false,"videoSources":[{"plugin_type":"UMPSource","url":"https://example.com/ump","ustreamerConfig":"AQ","videoFormats":[{"itag":137,"lastModified":"18446744073709551615","mimeType":"video/mp4","height":1080}],"audioFormats":[{"itag":140,"lastModified":"7","mimeType":"audio/mp4"}]}]}}"#
        let details = try JSONDecoder().decode(VideoDetails.self, from: Data(json.utf8))
        let source = try XCTUnwrap(details.videoSources.first)
        XCTAssertEqual(source.videoFormats.first?.lastModified, UInt64.max)
        XCTAssertTrue(source.isUMP)
        XCTAssertEqual(PlaybackSelector.options(for: details).first?.kind, .ump)
    }

    func testUMPSourceDecodesContinuationTokenCallback() throws {
        let json = #"{"plugin_type":"UMPSource","url":"https://example.com/ump","ustreamerConfig":"AQ","poToken":"bootstrap","__handle":42,"hasRefreshUMPToken":true,"videoFormats":[],"audioFormats":[]}"#
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        XCTAssertEqual(source.poToken, "bootstrap")
        XCTAssertEqual(source.handle, 42)
        XCTAssertTrue(source.hasRefreshUMPToken)
    }

    func testPlaybackRequestUsesYouTubeSABRMetadataFields() async throws {
        let json = #"{"plugin_type":"UMPSource","url":"https://example.com/ump","ustreamerConfig":"AQ","videoFormats":[{"itag":137,"lastModified":"7","mimeType":"video/mp4","codecs":"avc1.640028","width":1920,"height":1080,"bitrate":2000000}],"audioFormats":[{"itag":140,"lastModified":"8","mimeType":"audio/mp4","codecs":"mp4a.40.2","bitrate":128000}]}"#
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(json.utf8))
        let session = try UMPSession(source: source)
        let root = try ProtoReader(await session.requestBodyForTesting()).fields()
        let infoData = try XCTUnwrap(root.first(where: { $0.number == 1 })?.bytes)
        let info = try ProtoReader(infoData).fields()
        let values = Dictionary(uniqueKeysWithValues: info.compactMap { field in
            field.varint.map { (field.number, $0) }
        })

        XCTAssertEqual(values[16], 1080)
        XCTAssertEqual(values[18], 1920)
        XCTAssertEqual(values[19], 1080)
        XCTAssertEqual(values[21], 1080)
        XCTAssertEqual(values[23], 104_857)
        XCTAssertEqual(values[34], 0)
        XCTAssertNotNil(values[13])
        XCTAssertNil(values[29])
        XCTAssertNotNil(values[39])
        XCTAssertNil(values[40])
        XCTAssertNil(values[44])
        XCTAssertEqual(values[58], 0)
        XCTAssertEqual(values[59], 1080)
        XCTAssertFalse(info.contains(where: { $0.number == 285 }))
    }

    func testBufferedStreamUsesStartThenDurationFieldOrder() throws {
        let fields = try ProtoReader(UMPSession.bufferedStreamForTesting(
            playbackPositionMS: 68_886,
            firstSequence: 1,
            lastSequence: 12
        )).fields()
        let values = Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            field.varint.map { (field.number, $0) }
        })

        XCTAssertEqual(values[2], 0)
        XCTAssertEqual(values[3], 68_886)
        XCTAssertEqual(values[4], 1)
        XCTAssertEqual(values[5], 12)
    }

    func testPlaylistAdvertisesKnownPresentationForSeeking() throws {
        let json = #"{"itag":137,"lastModified":"7","mimeType":"video/mp4","codecs":"avc1.640028","width":1920,"height":1080,"bitrate":2000000}"#
        let format = try JSONDecoder().decode(UMPFormat.self, from: Data(json.utf8))
        let track = UMPSession.TrackSnapshot(
            format: format,
            hasInitialization: true,
            segments: [UMPMediaChunk(sequence: 4, start: 0, duration: 5, data: Data())],
            finalSegment: 15,
            presentationDuration: 60,
            isComplete: false
        )

        let playlist = String(
            data: UMPMediaProxy.playlist(track, base: "/session", kind: "video"),
            encoding: .utf8
        )
        XCTAssertNotNil(playlist)
        XCTAssertTrue(playlist?.contains("/session/video/4.m4s") == true)
        XCTAssertTrue(playlist?.contains("/session/video/5.m4s") == true)
        XCTAssertTrue(playlist?.contains("/session/video/15.m4s") == true)
        XCTAssertEqual(playlist?.components(separatedBy: "#EXTINF:").count, 13)
        XCTAssertTrue(playlist?.contains("#EXT-X-PLAYLIST-TYPE:VOD") == true)
        XCTAssertTrue(playlist?.contains("#EXT-X-ENDLIST") == true)
    }
}
