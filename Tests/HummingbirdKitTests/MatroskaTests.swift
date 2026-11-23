import Foundation
import XCTest
@testable import HummingbirdKit

/// WebM files are served as fragmented MP4 like progressive MP4 files, on
/// every platform: the seek index gives segments at keyframes, each segment
/// carries exactly its track's frames, and formats MP4 cannot carry fail with
/// their name.
final class MatroskaTests: XCTestCase {
    private typealias M = Matroska
    private typealias P = ProgressiveMP4

    // MARK: building a file

    private func idBytes(_ id: UInt32) -> [UInt8] {
        let all = P.be32Bytes(id)
        return Array(all.drop { $0 == 0 })
    }

    /// An element with an 8-byte size.
    private func element(_ id: UInt32, _ content: [UInt8]) -> [UInt8] {
        let size = UInt64(content.count)
        let sizeBytes: [UInt8] = [0x01] + (0..<7).reversed().map { UInt8(size >> (8 * UInt64($0)) & 0xFF) }
        return idBytes(id) + sizeBytes + content
    }

    private func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        element(id, (0..<8).reversed().map { UInt8(value >> (8 * UInt64($0)) & 0xFF) })
    }

    private func simpleBlock(track: UInt8, relative: Int16, key: Bool, _ payload: [UInt8]) -> [UInt8] {
        let time = UInt16(bitPattern: relative)
        return element(M.ID.simpleBlock, [0x80 | track, UInt8(time >> 8), UInt8(time & 0xFF), key ? 0x80 : 0] + payload)
    }

    /// A VP9 profile 0 keyframe header (BT.709, limited range), then filler.
    private func vp9Keyframe(_ fill: UInt8) -> [UInt8] { [0x82, 0x49, 0x83, 0x42, 0x40] + [UInt8](repeating: fill, count: 20) }
    private func vp9Inter(_ fill: UInt8) -> [UInt8] { [0x86] + [UInt8](repeating: fill, count: 10) }
    private func opus(_ fill: UInt8) -> [UInt8] { [UInt8](repeating: fill, count: 7) }

    private struct Fixture {
        var bytes: [UInt8]
        var video: [[UInt8]]
        var audio: [[UInt8]]
    }

    /// Video (VP9, track 1) keyframes at 0 and 5 s, frames every second;
    /// audio (Opus, track 2) every 500 ms. Cues index the video only.
    private func makeFile(audioCodec: String = "A_OPUS", cues: Bool = true) -> Fixture {
        let header = element(M.ID.ebml, element(M.ID.docType, Array("webm".utf8)))
        let durationBits = Double(8000).bitPattern
        let info = element(M.ID.info, uint(M.ID.timecodeScale, 1_000_000)
                           + element(M.ID.duration, (0..<8).reversed().map { UInt8(durationBits >> (8 * UInt64($0)) & 0xFF) }))
        let opusHead: [UInt8] = Array("OpusHead".utf8) + [1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tracks = element(M.ID.tracks,
                             element(M.ID.trackEntry, uint(M.ID.trackNumber, 1) + uint(M.ID.trackType, 1)
                                     + element(M.ID.codecID, Array("V_VP9".utf8))
                                     + element(M.ID.video, uint(M.ID.pixelWidth, 1920) + uint(M.ID.pixelHeight, 1080)))
                             + element(M.ID.trackEntry, uint(M.ID.trackNumber, 2) + uint(M.ID.trackType, 2)
                                       + element(M.ID.codecID, Array(audioCodec.utf8))
                                       + element(M.ID.codecPrivate, opusHead)
                                       + element(M.ID.audio, uint(M.ID.channels, 2))))
        var video: [[UInt8]] = []
        var audio: [[UInt8]] = []
        func cluster(at start: Int, frames: Int) -> [UInt8] {
            var content = uint(M.ID.timestamp, UInt64(start))
            for second in 0..<frames {
                let frame = second == 0 ? vp9Keyframe(UInt8(start / 1000 + second)) : vp9Inter(UInt8(start / 1000 + second))
                video.append(frame)
                content += simpleBlock(track: 1, relative: Int16(second * 1000), key: second == 0, frame)
                for half in 0..<2 {
                    let sample = opus(UInt8(0xA0 + audio.count))
                    audio.append(sample)
                    content += simpleBlock(track: 2, relative: Int16(second * 1000 + half * 500), key: true, sample)
                }
            }
            return element(M.ID.cluster, content)
        }
        let first = cluster(at: 0, frames: 5)
        let second = cluster(at: 5000, frames: 3)
        // Cue positions are relative to the segment's data; the cues element
        // has a fixed size, so it can be built with placeholder positions first.
        func cuesElement(_ firstPosition: UInt64, _ secondPosition: UInt64) -> [UInt8] {
            element(M.ID.cues,
                    element(M.ID.cuePoint, uint(M.ID.cueTime, 0)
                            + element(M.ID.cueTrackPositions, uint(M.ID.cueTrack, 1) + uint(M.ID.cueClusterPosition, firstPosition)))
                    + element(M.ID.cuePoint, uint(M.ID.cueTime, 5000)
                              + element(M.ID.cueTrackPositions, uint(M.ID.cueTrack, 1) + uint(M.ID.cueClusterPosition, secondPosition))))
        }
        let before = info + tracks
        let cueSize = cues ? cuesElement(0, 0).count : 0
        let firstPosition = UInt64(before.count + cueSize)
        let secondPosition = firstPosition + UInt64(first.count)
        let body = before + (cues ? cuesElement(firstPosition, secondPosition) : []) + first + second
        return Fixture(bytes: header + element(M.ID.segment, body), video: video, audio: audio)
    }

    private func reader(_ bytes: [UInt8]) -> RemuxRead {
        let data = Data(bytes)
        return { range in
            let clamped = range.clamped(to: 0..<Int64(data.count))
            return data.subdata(in: Int(clamped.lowerBound)..<Int(clamped.upperBound))
        }
    }

    // MARK: reading fragments back

    private struct Fragment {
        var decodeTime: UInt64
        var durations: [UInt32]
        var sync: [Bool]
        var payload: [UInt8]
    }

    private func parseFragment(_ data: Data) throws -> Fragment {
        let bytes = [UInt8](data)
        let top = P.children(bytes, in: 0..<bytes.count)
        let moof = try XCTUnwrap(top.first { $0.type == "moof" })
        let mdat = try XCTUnwrap(top.first { $0.type == "mdat" })
        let traf = try XCTUnwrap(P.children(bytes, in: (moof.range.lowerBound + 8)..<moof.range.upperBound).first { $0.type == "traf" })
        let parts = P.children(bytes, in: (traf.range.lowerBound + 8)..<traf.range.upperBound)
        let tfdt = try XCTUnwrap(parts.first { $0.type == "tfdt" })
        let trun = try XCTUnwrap(parts.first { $0.type == "trun" })
        let count = Int(P.be32(bytes, trun.range.lowerBound + 12))
        var durations: [UInt32] = []
        var sync: [Bool] = []
        for index in 0..<count {
            let at = trun.range.lowerBound + 20 + index * 16
            durations.append(P.be32(bytes, at))
            sync.append(P.be32(bytes, at + 8) == 0x0200_0000)
        }
        return Fragment(decodeTime: P.be64(bytes, tfdt.range.lowerBound + 12), durations: durations, sync: sync,
                        payload: Array(bytes[(mdat.range.lowerBound + 8)..<mdat.range.upperBound]))
    }

    // MARK: tests

    func testReadsTracksCuesAndDuration() async throws {
        let fixture = makeFile()
        let file = try await M.open(total: Int64(fixture.bytes.count), read: reader(fixture.bytes))
        XCTAssertEqual(file.timecodeScale, 1_000_000)
        XCTAssertEqual(file.seconds, 8)
        XCTAssertEqual(file.track(.video)?.codecID, "V_VP9")
        XCTAssertEqual(file.track(.video)?.width, 1920)
        XCTAssertEqual(file.track(.audio)?.codecID, "A_OPUS")
        XCTAssertEqual(file.cues.map(\.time), [0, 5000])
        let segments = M.segments(of: file, track: try XCTUnwrap(file.track(.video)))
        XCTAssertEqual(segments.map(\.start), [0, 5000])
        XCTAssertEqual(segments.map(\.end), [5000, 8000], "the last segment ends at the file's duration")
    }

    func testVideoSegmentsCarryExactlyTheirFramesFromAKeyframe() async throws {
        let fixture = makeFile()
        let read = reader(fixture.bytes)
        let file = try await M.open(total: Int64(fixture.bytes.count), read: read)
        let source = try await WebMRemuxSource.make(file: file, track: try XCTUnwrap(file.track(.video)), read: read)
        XCTAssertEqual(source.codecs, "vp09.00.41.08")
        XCTAssertEqual(source.segmentDurations, [5, 3])

        let first = try parseFragment(try await source.mediaSegment(0, read: read))
        XCTAssertEqual(first.payload, Array(fixture.video[0..<5].joined()))
        XCTAssertEqual(first.durations, [1000, 1000, 1000, 1000, 1000])
        XCTAssertEqual(first.sync, [true, false, false, false, false])
        XCTAssertEqual(first.decodeTime, 0)
        let second = try parseFragment(try await source.mediaSegment(1, read: read))
        XCTAssertEqual(second.payload, Array(fixture.video[5..<8].joined()))
        XCTAssertEqual(second.decodeTime, 5000)
        XCTAssertEqual(second.durations.last, 1000, "the last frame lasts until the file ends")

        let initialization = [UInt8](try await source.initializationSegment(read: read))
        let text = String(decoding: initialization, as: UTF8.self)
        XCTAssertTrue(text.contains("vp09") && text.contains("vpcC") && text.contains("mvex"))
    }

    func testAudioIsCutAtTheVideoCuesAndDescribedAsOpus() async throws {
        let fixture = makeFile()
        let read = reader(fixture.bytes)
        let file = try await M.open(total: Int64(fixture.bytes.count), read: read)
        let source = try await WebMRemuxSource.make(file: file, track: try XCTUnwrap(file.track(.audio)), read: read)
        XCTAssertEqual(source.codecs, "opus")
        let first = try parseFragment(try await source.mediaSegment(0, read: read))
        XCTAssertEqual(first.payload, Array(fixture.audio[0..<10].joined()))
        XCTAssertTrue(first.durations.allSatisfy { $0 == 500 })
        let initialization = [UInt8](try await source.initializationSegment(read: read))
        let text = String(decoding: initialization, as: UTF8.self)
        XCTAssertTrue(text.contains("Opus") && text.contains("dOps") && text.contains("soun"))
        // dOps: version 0, 2 channels, pre-skip 312 (big-endian), 48 kHz.
        let marker = Array("dOps".utf8)
        let found = try XCTUnwrap((0..<(initialization.count - 4)).first { Array(initialization[$0..<($0 + 4)]) == marker })
        let dOps = found + 4
        XCTAssertEqual(Array(initialization[dOps..<(dOps + 8)]), [0, 2, 0x01, 0x38, 0, 0, 0xBB, 0x80])
    }

    func testAFileWithoutCuesIsIndexedByItsClusters() async throws {
        let fixture = makeFile(cues: false)
        let file = try await M.open(total: Int64(fixture.bytes.count), read: reader(fixture.bytes))
        XCTAssertEqual(file.cues.map(\.time), [0, 5000])
    }

    func testVorbisFailsWithItsName() async throws {
        let fixture = makeFile(audioCodec: "A_VORBIS")
        let read = reader(fixture.bytes)
        let file = try await M.open(total: Int64(fixture.bytes.count), read: read)
        do {
            _ = try await WebMRemuxSource.make(file: file, track: try XCTUnwrap(file.track(.audio)), read: read)
            XCTFail("Vorbis has no MP4 sample entry")
        } catch let failure as M.Failure {
            XCTAssertEqual(failure, .unsupportedCodec("Vorbis audio"))
            XCTAssertTrue(failure.localizedDescription.contains("Vorbis audio"), "the message names the format")
        }
    }

    func testAnMP4IsNotMatroska() async {
        let mp4 = P.box("ftyp", Array("isom".utf8) + P.be32Bytes(0)) + [UInt8](repeating: 0, count: 40)
        do {
            _ = try await M.open(total: Int64(mp4.count), read: reader(mp4))
            XCTFail("an MP4 is not WebM")
        } catch {
            XCTAssertEqual(error as? M.Failure, .notMatroska)
        }
    }

    func testXiphLacedFramesAreSplit() throws {
        // Track 2, time 0, Xiph lacing, 3 frames of 3, 300 and 2 bytes.
        let frames: [[UInt8]] = [[1, 1, 1], [UInt8](repeating: 2, count: 300), [3, 3]]
        let lacing: [UInt8] = [2, 3, 255, 45]
        let block = [0x82, 0, 0, 0x80 | 0x02] + lacing + frames.joined()
        let cluster = element(M.ID.cluster, uint(M.ID.timestamp, 0) + element(M.ID.simpleBlock, block))
        let parsed = try M.frames(in: cluster, trackNumber: 2)
        XCTAssertEqual(parsed.map { Array(cluster[$0.data]) }, frames)
    }

    /// Generated (DASH) WebM: an initialization segment of headers and
    /// tracks, then media segments of clusters, each remuxed as it is served.
    func testWebMDashSegmentsBecomeFragmentedMP4() throws {
        let header = element(M.ID.ebml, element(M.ID.docType, Array("webm".utf8)))
        let tracks = element(M.ID.tracks,
                             element(M.ID.trackEntry, uint(M.ID.trackNumber, 1) + uint(M.ID.trackType, 1)
                                     + element(M.ID.codecID, Array("V_VP9".utf8))
                                     + element(M.ID.video, uint(M.ID.pixelWidth, 1280) + uint(M.ID.pixelHeight, 720))))
        // A live-style segment of unknown size.
        let initialization = header + idBytes(M.ID.segment) + [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            + element(M.ID.info, uint(M.ID.timecodeScale, 1_000_000)) + tracks
        let frames = [vp9Keyframe(1), vp9Inter(2), vp9Inter(3)]
        var content = uint(M.ID.timestamp, 10_000)
        for (index, frame) in frames.enumerated() {
            content += simpleBlock(track: 1, relative: Int16(index * 1000), key: index == 0, frame)
        }
        let media = element(M.ID.cluster, content)

        let track = try WebMDashTrack(initialization: initialization, firstSegment: media)
        XCTAssertEqual(track.description.codecs, "vp09.00.31.08")
        let text = String(decoding: track.initializationSegment(), as: UTF8.self)
        XCTAssertTrue(text.contains("vp09") && text.contains("mvex"))
        let fragment = try parseFragment(try track.mediaSegment(media, index: 2, start: 10, duration: 3))
        XCTAssertEqual(fragment.payload, Array(frames.joined()))
        XCTAssertEqual(fragment.decodeTime, 10_000, "cluster times are absolute")
        XCTAssertEqual(fragment.durations, [1000, 1000, 1000], "the last frame lasts to the segment's end")
        XCTAssertEqual(fragment.sync, [true, false, false])
    }

    func testWebMDashManifestOmitsCodecsAndKnowsItsSegments() throws {
        let mpd = """
        <MPD><Period><AdaptationSet contentType="video" mimeType="video/webm">
        <Representation id="v" bandwidth="1000" width="1280" height="720" codecs="vp9">
        <SegmentTemplate timescale="1000" startNumber="1" initialization="https://grayjay.internal/video/init.webm" media="https://grayjay.internal/video/$Number$.webm">
        <SegmentTimeline><S d="4000" r="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
        """
        let result = try DashToHLS.convert(mpd, baseURL: "http://127.0.0.1:1/x")
        XCTAssertFalse(result.master.contains("CODECS"), "vp9 is no MP4 codec string")
        let timeline = try XCTUnwrap(result.webm["video"])
        XCTAssertEqual(timeline.initialization, "/video/init.webm")
        XCTAssertEqual(timeline.index["/video/2.webm"], 1)
        XCTAssertEqual(timeline.starts, [0, 4])
    }

    func testVP9HeaderGivesProfileDepthAndChroma() {
        let header = M.VP9Header(vp9Keyframe(0))
        XCTAssertEqual(header?.profile, 0)
        XCTAssertEqual(header?.bitDepth, 8)
        XCTAssertEqual(header?.chroma, 1)
        XCTAssertEqual(header?.colourSpace, 2)
        XCTAssertNil(M.VP9Header(vp9Inter(0)), "only a keyframe describes the stream")
    }
}
