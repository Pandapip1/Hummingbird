import Foundation
import XCTest
@testable import HummingbirdKit

/// Progressive MP4 files are served as fragmented MP4 (so every cached video
/// is HLS and takes subtitle renditions): the sample tables are read, video
/// is cut at sync samples, and each fragment carries exactly its samples.
final class ProgressiveMP4Tests: XCTestCase {
    private typealias P = ProgressiveMP4

    /// A two-track file: video samples in chunks [0 1] [2 3 4] [5], audio [0 1] [2 3], interleaved.
    private struct Fixture {
        var file: [UInt8]
        var videoSamples: [[UInt8]]
        var audioSamples: [[UInt8]]
    }

    private func makeFixture(moovAtEnd: Bool = false) -> Fixture {
        let video = (0..<6).map { index in [UInt8](repeating: UInt8(0x10 + index), count: 100 + index * 10) }
        let audio = (0..<4).map { index in [UInt8](repeating: UInt8(0xA0 + index), count: 20 + index) }
        // mdat payload order: V0 V1 | A0 A1 | V2 V3 V4 | A2 A3 | V5
        let order: [(Bool, Int)] = [(true, 0), (true, 1), (false, 0), (false, 1), (true, 2), (true, 3), (true, 4),
                                    (false, 2), (false, 3), (true, 5)]
        let fileType = P.box("ftyp", Array("isom".utf8) + P.be32Bytes(0) + Array("isommp41".utf8))
        func movie(mdatPayloadStart: Int64) -> [UInt8] {
            var position = mdatPayloadStart
            var chunkStarts: [String: Int64] = [:]
            for (index, item) in order.enumerated() {
                let key = item.0 ? "v\(item.1)" : "a\(item.1)"
                chunkStarts[key] = position
                position += Int64(item.0 ? video[item.1].count : audio[item.1].count)
                _ = index
            }
            let videoChunks = [chunkStarts["v0"]!, chunkStarts["v2"]!, chunkStarts["v5"]!]
            let audioChunks = [chunkStarts["a0"]!, chunkStarts["a2"]!]
            func trak(id: UInt32, handler: String, sizes: [Int], delta: UInt32, sync: [UInt32]?,
                      stsc: [(UInt32, UInt32)], chunks: [Int64]) -> [UInt8] {
                let tkhd = P.fullBox("tkhd", version: 0, flags: 7,
                                     P.be32Bytes(0) + P.be32Bytes(0) + P.be32Bytes(id) + [UInt8](repeating: 0, count: 60)
                                     + P.be32Bytes(1280 << 16) + P.be32Bytes(720 << 16))
                let mdhd = P.fullBox("mdhd", version: 0, flags: 0,
                                     P.be32Bytes(0) + P.be32Bytes(0) + P.be32Bytes(1000) + P.be32Bytes(0) + [0, 0, 0, 0])
                let hdlr = P.fullBox("hdlr", version: 0, flags: 0, P.be32Bytes(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
                let stsd = P.fullBox("stsd", version: 0, flags: 0, P.be32Bytes(1) + P.box(handler == "vide" ? "avc1" : "mp4a", [UInt8](repeating: 0, count: 8)))
                let stts = P.fullBox("stts", version: 0, flags: 0, P.be32Bytes(1) + P.be32Bytes(UInt32(sizes.count)) + P.be32Bytes(delta))
                let stsz = P.fullBox("stsz", version: 0, flags: 0,
                                     P.be32Bytes(0) + P.be32Bytes(UInt32(sizes.count)) + sizes.flatMap { P.be32Bytes(UInt32($0)) })
                let stscBox = P.fullBox("stsc", version: 0, flags: 0,
                                        P.be32Bytes(UInt32(stsc.count)) + stsc.flatMap { P.be32Bytes($0.0) + P.be32Bytes($0.1) + P.be32Bytes(1) })
                let stco = P.fullBox("stco", version: 0, flags: 0,
                                     P.be32Bytes(UInt32(chunks.count)) + chunks.flatMap { P.be32Bytes(UInt32($0)) })
                var tables = stsd + stts + stsz + stscBox + stco
                if let sync { tables += P.fullBox("stss", version: 0, flags: 0, P.be32Bytes(UInt32(sync.count)) + sync.flatMap(P.be32Bytes)) }
                let minf = P.box("minf", P.fullBox(handler == "vide" ? "vmhd" : "smhd", version: 0, flags: 1, [0, 0, 0, 0, 0, 0, 0, 0])
                                 + P.box("stbl", tables))
                return P.box("trak", tkhd + P.box("mdia", mdhd + hdlr + minf))
            }
            let mvhd = P.fullBox("mvhd", version: 0, flags: 0, P.be32Bytes(0) + P.be32Bytes(0) + P.be32Bytes(1000) + P.be32Bytes(6000)
                                 + [UInt8](repeating: 0, count: 80))
            return P.box("moov", mvhd
                         + trak(id: 1, handler: "vide", sizes: video.map(\.count), delta: 1000, sync: [1, 4],
                                stsc: [(1, 2), (2, 3), (3, 1)], chunks: videoChunks)
                         + trak(id: 2, handler: "soun", sizes: audio.map(\.count), delta: 1500, sync: nil,
                                stsc: [(1, 2)], chunks: audioChunks))
        }
        let payload = order.flatMap { $0.0 ? video[$0.1] : audio[$0.1] }
        let mdatHeader = P.be32Bytes(UInt32(8 + payload.count)) + Array("mdat".utf8)
        let file: [UInt8]
        if moovAtEnd {
            let start = Int64(fileType.count + mdatHeader.count)
            file = fileType + mdatHeader + payload + movie(mdatPayloadStart: start)
        } else {
            let size = movie(mdatPayloadStart: 0).count
            let start = Int64(fileType.count + size + mdatHeader.count)
            file = fileType + movie(mdatPayloadStart: start) + mdatHeader + payload
        }
        return Fixture(file: file, videoSamples: video, audioSamples: audio)
    }

    private func readMovie(_ fixture: Fixture) async throws -> P.Movie {
        let data = Data(fixture.file)
        let range = try await P.locateMovie(total: Int64(data.count)) { range in
            data.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, Int64(data.count))))
        }
        return try P.parseMovie(Array(fixture.file[Int(range.lowerBound)..<Int(range.upperBound)]))
    }

    func testSampleTablesAreReadWhereverTheMovieIs() async throws {
        for moovAtEnd in [false, true] {
            let fixture = makeFixture(moovAtEnd: moovAtEnd)
            let movie = try await readMovie(fixture)
            let video = try XCTUnwrap(movie.track(.video))
            let audio = try XCTUnwrap(movie.track(.audio))
            XCTAssertEqual(video.id, 1)
            XCTAssertEqual(video.width, 1280)
            XCTAssertEqual(video.samples.map(\.isSync), [true, false, false, true, false, false])
            XCTAssertEqual(audio.samples.count, 4)
            XCTAssertTrue(audio.samples.allSatisfy(\.isSync), "no stss: every sample is a sync sample")
            for (index, sample) in video.samples.enumerated() {
                let bytes = Array(fixture.file[Int(sample.offset)..<(Int(sample.offset) + sample.size)])
                XCTAssertEqual(bytes, fixture.videoSamples[index], "video sample \(index), moov at end: \(moovAtEnd)")
            }
            for (index, sample) in audio.samples.enumerated() {
                let bytes = Array(fixture.file[Int(sample.offset)..<(Int(sample.offset) + sample.size)])
                XCTAssertEqual(bytes, fixture.audioSamples[index])
            }
            XCTAssertEqual(video.duration, 6, accuracy: 0.001)
        }
    }

    func testVideoSegmentsStartAtSyncSamplesAndCarryExactlyTheirSamples() async throws {
        let fixture = makeFixture()
        let movie = try await readMovie(fixture)
        let video = try XCTUnwrap(movie.track(.video))
        let segments = P.segments(of: video, target: 2)
        XCTAssertEqual(segments.map(\.samples), [0..<3, 3..<6])
        XCTAssertEqual(segments.map(\.decodeTime), [0, 3000])
        XCTAssertEqual(segments.map(\.duration), [3, 3])

        let data = Data(fixture.file)
        let fragment = [UInt8](try await P.mediaSegment(video, segments[1], sequence: 2) { range in
            data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        })
        let top = P.children(fragment, in: 0..<fragment.count)
        XCTAssertEqual(top.map(\.type), ["moof", "mdat"])
        let mdat = top[1].range
        XCTAssertEqual(Array(fragment[(mdat.lowerBound + 8)..<mdat.upperBound]),
                       Array(fixture.videoSamples[3...5].joined()))
        // trun's data offset points at the first sample byte, counted from the moof.
        let moof = top[0].range
        let traf = try XCTUnwrap(P.children(fragment, in: (moof.lowerBound + 8)..<moof.upperBound).first { $0.type == "traf" })
        let trun = try XCTUnwrap(P.children(fragment, in: (traf.range.lowerBound + 8)..<traf.range.upperBound).first { $0.type == "trun" })
        XCTAssertEqual(P.be32(fragment, trun.range.lowerBound + 12), 3, "sample count")
        XCTAssertEqual(Int(P.be32(fragment, trun.range.lowerBound + 16)), mdat.lowerBound + 8 - moof.lowerBound)
        // The first sample of a segment is a sync sample.
        XCTAssertEqual(P.be32(fragment, trun.range.lowerBound + 20 + 8), 0x0200_0000)
    }

    func testInitializationSegmentHasEmptySampleTablesAndMovieExtends() async throws {
        let movie = try await readMovie(makeFixture())
        let audio = try XCTUnwrap(movie.track(.audio))
        let initialization = [UInt8](P.initializationSegment(movie: movie, track: audio))
        let top = P.children(initialization, in: 0..<initialization.count)
        XCTAssertEqual(top.map(\.type), ["ftyp", "moov"])
        let moov = Array(initialization[top[1].range])
        let parsed = try P.parseMovie(moov)
        XCTAssertEqual(parsed.tracks.count, 1)
        XCTAssertEqual(parsed.tracks.first?.id, 2)
        XCTAssertEqual(parsed.tracks.first?.samples.count, 0, "samples are described by each fragment")
        XCTAssertTrue(P.children(moov, in: 8..<moov.count).contains { $0.type == "mvex" })
    }

    func testOtherFilesAreNotRemuxed() async {
        let webm: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 60)
        let data = Data(webm)
        do {
            _ = try await P.locateMovie(total: Int64(data.count)) { range in
                data.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, Int64(data.count))))
            }
            XCTFail("a WebM file is not an MP4")
        } catch {
            XCTAssertEqual(error as? P.Failure, .notMP4)
        }
    }
}
