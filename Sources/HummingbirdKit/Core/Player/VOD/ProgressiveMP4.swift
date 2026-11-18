import Foundation

/// Serves a progressive (non-fragmented) MP4 or QuickTime file as fragmented
/// MP4, so every cached video is an HLS presentation: subtitles and other
/// renditions attach to it the same way for every source.
///
/// Nothing is re-encoded and no second copy is stored. The file's `moov`
/// sample tables say where each sample lies; an initialization segment is
/// the same movie with empty sample tables and `mvex`, and each media
/// segment is a `moof` describing a run of samples followed by an `mdat`
/// holding those samples' bytes, read from the cached file as it downloads.
enum ProgressiveMP4 {
    enum Failure: Error, Equatable {
        case notMP4
        case malformed(String)
    }

    enum Kind: Sendable, Equatable { case video, audio, other }

    struct Sample: Sendable, Equatable {
        var offset: Int64
        var size: Int
        /// Decode duration, in the track's timescale.
        var duration: UInt32
        /// Composition (presentation) offset, in the track's timescale.
        var compositionOffset: Int32
        var isSync: Bool
    }

    struct Track: Sendable, Equatable {
        var id: UInt32
        var kind: Kind
        var timescale: UInt32
        var samples: [Sample]
        /// The original `trak` box, rewritten for the initialization segment.
        var trak: [UInt8]
        var width: Int
        var height: Int
        var duration: Double {
            Double(samples.reduce(UInt64(0)) { $0 + UInt64($1.duration) }) / Double(max(timescale, 1))
        }
    }

    struct Movie: Sendable, Equatable {
        var mvhd: [UInt8]
        var tracks: [Track]
        func track(_ kind: Kind) -> Track? { tracks.first { $0.kind == kind && !$0.samples.isEmpty } }
    }

    /// A run of samples served as one media segment.
    struct Segment: Sendable, Equatable {
        var samples: Range<Int>
        /// Decode time of the first sample, in the track's timescale.
        var decodeTime: UInt64
        var duration: Double
        /// The file bytes the segment's samples occupy (first to last).
        var bytes: Range<Int64>
    }

    // MARK: locating the movie

    /// Where `ftyp` and `moov` lie, reading box headers through `read`
    /// (which waits for the bytes). `moov` may come after the media (files
    /// not prepared for streaming): the header walk skips `mdat`.
    static func locateMovie(total: Int64, read: (Range<Int64>) async throws -> Data) async throws -> Range<Int64> {
        var offset: Int64 = 0
        var sawFileType = false
        while offset + 8 <= total {
            let header = [UInt8](try await read(offset..<min(total, offset + 16)))
            guard header.count >= 8 else { throw Failure.malformed("short box header") }
            let size32 = UInt64(be32(header, 0))
            let type = fourCC(header, 4)
            var size = Int64(size32)
            if size32 == 1 {
                guard header.count >= 16 else { throw Failure.malformed("short large-size header") }
                size = Int64(be64(header, 8))
            } else if size32 == 0 {
                size = total - offset
            }
            guard size >= 8 else { throw Failure.malformed("box size") }
            if offset == 0 {
                guard ["ftyp", "moov", "free", "skip", "wide", "mdat"].contains(type) else { throw Failure.notMP4 }
            }
            if type == "ftyp" { sawFileType = true }
            if type == "moov" { return offset..<(offset + size) }
            if type == "moof" { throw Failure.notMP4 } // already fragmented
            offset += size
        }
        throw sawFileType ? Failure.malformed("no moov") : Failure.notMP4
    }

    // MARK: parsing

    static func parseMovie(_ moovBox: [UInt8]) throws -> Movie {
        guard moovBox.count >= 8, fourCC(moovBox, 4) == "moov" else { throw Failure.malformed("not a moov box") }
        var mvhd: [UInt8]?
        var tracks: [Track] = []
        for child in children(moovBox, in: 8..<moovBox.count) {
            switch child.type {
            case "mvhd": mvhd = Array(moovBox[child.range])
            case "trak": if let track = try parseTrack(Array(moovBox[child.range])) { tracks.append(track) }
            default: break
            }
        }
        guard let mvhd else { throw Failure.malformed("no mvhd") }
        return Movie(mvhd: mvhd, tracks: tracks)
    }

    private static func parseTrack(_ trak: [UInt8]) throws -> Track? {
        guard let tkhd = find(["tkhd"], in: trak),
              let mdhd = find(["mdia", "mdhd"], in: trak),
              let hdlr = find(["mdia", "hdlr"], in: trak),
              let stbl = find(["mdia", "minf", "stbl"], in: trak) else { return nil }
        let tkhdVersion = trak[tkhd.lowerBound]
        let trackID = be32(trak, tkhd.lowerBound + (tkhdVersion == 1 ? 20 : 12))
        let width = Int(be32(trak, tkhd.upperBound - 8) >> 16)
        let height = Int(be32(trak, tkhd.upperBound - 4) >> 16)
        let mdhdVersion = trak[mdhd.lowerBound]
        let timescale = be32(trak, mdhd.lowerBound + (mdhdVersion == 1 ? 20 : 12))
        guard timescale > 0 else { throw Failure.malformed("timescale") }
        let kind: Kind = switch fourCC(trak, hdlr.lowerBound + 8) {
        case "vide": .video
        case "soun": .audio
        default: .other
        }
        let table = SampleTable(bytes: trak, stbl: stbl)
        return Track(id: trackID, kind: kind, timescale: timescale, samples: try table.samples(),
                     trak: trak, width: width, height: height)
    }

    /// The sample tables of one track (ISO/IEC 14496-12 §8.6–8.7).
    private struct SampleTable {
        let bytes: [UInt8]
        let stbl: Range<Int>

        func box(_ type: String) -> Range<Int>? {
            children(bytes, in: stbl).first { $0.type == type }.map { $0.range.lowerBound + 8..<$0.range.upperBound }
        }

        func samples() throws -> [Sample] {
            // Sizes.
            var sizes: [Int] = []
            if let stsz = box("stsz") {
                let fixed = Int(be32(bytes, stsz.lowerBound + 4))
                let count = Int(be32(bytes, stsz.lowerBound + 8))
                if fixed != 0 {
                    sizes = Array(repeating: fixed, count: count)
                } else {
                    guard stsz.lowerBound + 12 + count * 4 <= stsz.upperBound else { throw Failure.malformed("stsz") }
                    sizes = (0..<count).map { Int(be32(bytes, stsz.lowerBound + 12 + $0 * 4)) }
                }
            } else if let stz2 = box("stz2") {
                let field = Int(bytes[stz2.lowerBound + 7])
                let count = Int(be32(bytes, stz2.lowerBound + 8))
                let base = stz2.lowerBound + 12
                sizes = (0..<count).map { index in
                    switch field {
                    case 4: Int(index % 2 == 0 ? bytes[base + index / 2] >> 4 : bytes[base + index / 2] & 0xF)
                    case 8: Int(bytes[base + index])
                    default: Int(UInt16(bytes[base + index * 2]) << 8 | UInt16(bytes[base + index * 2 + 1]))
                    }
                }
            } else {
                throw Failure.malformed("no sample sizes")
            }
            let count = sizes.count
            guard count > 0 else { return [] }

            // Decode durations.
            guard let stts = box("stts") else { throw Failure.malformed("no stts") }
            var durations: [UInt32] = []
            durations.reserveCapacity(count)
            for entry in 0..<Int(be32(bytes, stts.lowerBound + 4)) {
                let at = stts.lowerBound + 8 + entry * 8
                guard at + 8 <= stts.upperBound else { throw Failure.malformed("stts") }
                durations.append(contentsOf: repeatElement(be32(bytes, at + 4), count: Int(be32(bytes, at))))
            }
            guard durations.count >= count else { throw Failure.malformed("stts covers too few samples") }

            // Composition offsets.
            var offsets = [Int32](repeating: 0, count: count)
            if let ctts = box("ctts") {
                var index = 0
                for entry in 0..<Int(be32(bytes, ctts.lowerBound + 4)) {
                    let at = ctts.lowerBound + 8 + entry * 8
                    guard at + 8 <= ctts.upperBound else { throw Failure.malformed("ctts") }
                    let value = Int32(bitPattern: be32(bytes, at + 4))
                    for _ in 0..<Int(be32(bytes, at)) where index < count { offsets[index] = value; index += 1 }
                }
            }

            // Sync samples (all of them when there is no table).
            var sync = [Bool](repeating: box("stss") == nil, count: count)
            if let stss = box("stss") {
                for entry in 0..<Int(be32(bytes, stss.lowerBound + 4)) {
                    let number = Int(be32(bytes, stss.lowerBound + 8 + entry * 4))
                    if number >= 1, number <= count { sync[number - 1] = true }
                }
            }

            // Chunk offsets and samples per chunk.
            var chunkOffsets: [Int64] = []
            if let stco = box("stco") {
                chunkOffsets = (0..<Int(be32(bytes, stco.lowerBound + 4))).map { Int64(be32(bytes, stco.lowerBound + 8 + $0 * 4)) }
            } else if let co64 = box("co64") {
                chunkOffsets = (0..<Int(be32(bytes, co64.lowerBound + 4))).map { Int64(be64(bytes, co64.lowerBound + 8 + $0 * 8)) }
            } else {
                throw Failure.malformed("no chunk offsets")
            }
            guard let stsc = box("stsc") else { throw Failure.malformed("no stsc") }
            let runs = (0..<Int(be32(bytes, stsc.lowerBound + 4))).map { entry -> (firstChunk: Int, perChunk: Int) in
                let at = stsc.lowerBound + 8 + entry * 12
                return (Int(be32(bytes, at)), Int(be32(bytes, at + 4)))
            }
            guard !runs.isEmpty else { throw Failure.malformed("empty stsc") }

            var samples: [Sample] = []
            samples.reserveCapacity(count)
            var sample = 0
            for (chunkIndex, chunkOffset) in chunkOffsets.enumerated() where sample < count {
                let chunk = chunkIndex + 1
                let run = runs.last { $0.firstChunk <= chunk } ?? runs[0]
                var offset = chunkOffset
                for _ in 0..<run.perChunk where sample < count {
                    samples.append(Sample(offset: offset, size: sizes[sample], duration: durations[sample],
                                          compositionOffset: offsets[sample], isSync: sync[sample]))
                    offset += Int64(sizes[sample])
                    sample += 1
                }
            }
            guard samples.count == count else { throw Failure.malformed("chunks cover too few samples") }
            return samples
        }
    }

    // MARK: segments

    /// Media segments of about `target` seconds; video segments start at sync samples.
    static func segments(of track: Track, target: Double = 4) -> [Segment] {
        var segments: [Segment] = []
        var start = 0
        var decodeTime: UInt64 = 0
        var segmentTicks: UInt64 = 0
        let targetTicks = UInt64(target * Double(track.timescale))
        func close(at end: Int) {
            guard end > start else { return }
            let span = track.samples[start..<end]
            let low = span.map(\.offset).min() ?? 0
            let high = span.map { $0.offset + Int64($0.size) }.max() ?? low
            segments.append(Segment(samples: start..<end, decodeTime: decodeTime,
                                    duration: Double(segmentTicks) / Double(track.timescale), bytes: low..<high))
            decodeTime += segmentTicks
            segmentTicks = 0
            start = end
        }
        for (index, sample) in track.samples.enumerated() {
            let boundary = track.kind == .video ? sample.isSync : true
            if index > start, segmentTicks >= targetTicks, boundary { close(at: index) }
            segmentTicks += UInt64(sample.duration)
        }
        close(at: track.samples.count)
        return segments
    }

    // MARK: writing

    /// The initialization segment for `track`: `ftyp` + a `moov` with the
    /// track's sample description, empty sample tables and `mvex`.
    static func initializationSegment(movie: Movie, track: Track) -> Data {
        let fileType = box("ftyp", Array("iso6".utf8) + be32Bytes(0) + Array("iso6isommp41".utf8))
        let movieExtends = box("mvex", fullBox("trex", version: 0, flags: 0,
                                                be32Bytes(track.id) + be32Bytes(1) + be32Bytes(0) + be32Bytes(0) + be32Bytes(0)))
        let movieBox = box("moov", movie.mvhd + rewrite(track.trak, path: []) + movieExtends)
        return Data(fileType + movieBox)
    }

    /// Copies a box, replacing the sample tables in `trak/mdia/minf/stbl`
    /// with empty ones (the samples are described by each `moof`).
    private static func rewrite(_ boxBytes: [UInt8], path: [String]) -> [UInt8] {
        let type = fourCC(boxBytes, 4)
        let containers: Set<String> = ["trak", "mdia", "minf"]
        if type == "stbl" {
            var content: [UInt8] = []
            for child in children(boxBytes, in: 8..<boxBytes.count) where child.type == "stsd" {
                content += boxBytes[child.range]
            }
            content += fullBox("stts", version: 0, flags: 0, be32Bytes(0))
            content += fullBox("stsc", version: 0, flags: 0, be32Bytes(0))
            content += fullBox("stsz", version: 0, flags: 0, be32Bytes(0) + be32Bytes(0))
            content += fullBox("stco", version: 0, flags: 0, be32Bytes(0))
            return box("stbl", content)
        }
        guard containers.contains(type) else { return boxBytes }
        var content: [UInt8] = []
        for child in children(boxBytes, in: 8..<boxBytes.count) {
            content += rewrite(Array(boxBytes[child.range]), path: path + [type])
        }
        return box(type, content)
    }

    /// The byte ranges of the file the segment needs, coalesced.
    static func sourceRanges(_ track: Track, _ segment: Segment) -> [Range<Int64>] {
        var ranges: [Range<Int64>] = []
        for sample in track.samples[segment.samples] {
            let range = sample.offset..<(sample.offset + Int64(sample.size))
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// One media segment: `moof` + `mdat` with the samples' bytes, read
    /// through `read` (which waits for them to be cached).
    static func mediaSegment(_ track: Track, _ segment: Segment, sequence: UInt32,
                             read: (Range<Int64>) async throws -> Data) async throws -> Data {
        var payload = Data()
        for range in sourceRanges(track, segment) {
            let bytes = try await read(range)
            guard Int64(bytes.count) == Int64(range.count) else { throw Failure.malformed("short sample read") }
            payload.append(bytes)
        }
        return Data(fragmentHeader(track, segment, sequence: sequence, payloadSize: payload.count)) + payload
    }

    /// `moof` and the `mdat` header for a segment whose sample bytes total `payloadSize`.
    static func fragmentHeader(_ track: Track, _ segment: Segment, sequence: UInt32, payloadSize: Int) -> [UInt8] {
        let samples = track.samples[segment.samples]
        let movieFragmentHeader = fullBox("mfhd", version: 0, flags: 0, be32Bytes(sequence))
        // default-base-is-moof: data offsets count from this moof.
        let trackFragmentHeader = fullBox("tfhd", version: 0, flags: 0x02_0000, be32Bytes(track.id))
        let decodeTime = fullBox("tfdt", version: 1, flags: 0, be64Bytes(segment.decodeTime))
        // data-offset, sample duration, size, flags and composition offset present.
        let runFlags: UInt32 = 0x0001 | 0x0100 | 0x0200 | 0x0400 | 0x0800
        let runSize = 12 + 4 + 4 + samples.count * 16
        let trackFragmentSize = 8 + movieFragmentHeaderSize(trackFragmentHeader, decodeTime) + runSize
        let movieFragmentSize = 8 + movieFragmentHeader.count + trackFragmentSize
        var run = be32Bytes(UInt32(samples.count)) + be32Bytes(UInt32(movieFragmentSize + 8))
        for sample in samples {
            run += be32Bytes(sample.duration) + be32Bytes(UInt32(sample.size))
            run += be32Bytes(sample.isSync ? 0x0200_0000 : 0x0101_0000)
            run += be32Bytes(UInt32(bitPattern: sample.compositionOffset))
        }
        let trackRun = fullBox("trun", version: 1, flags: runFlags, run)
        let fragment = box("moof", movieFragmentHeader + box("traf", trackFragmentHeader + decodeTime + trackRun))
        return fragment + be32Bytes(UInt32(8 + payloadSize)) + Array("mdat".utf8)
    }

    private static func movieFragmentHeaderSize(_ tfhd: [UInt8], _ tfdt: [UInt8]) -> Int { tfhd.count + tfdt.count }

    // MARK: bytes

    struct Child { var type: String; var range: Range<Int> }

    static func children(_ bytes: [UInt8], in range: Range<Int>) -> [Child] {
        var result: [Child] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(be32(bytes, offset))
            if size == 1, offset + 16 <= range.upperBound { size = Int(be64(bytes, offset + 8)) }
            if size == 0 { size = range.upperBound - offset }
            guard size >= 8, offset + size <= range.upperBound else { break }
            result.append(Child(type: fourCC(bytes, offset + 4), range: offset..<(offset + size)))
            offset += size
        }
        return result
    }

    /// The payload range (after the box header) of the box at `path` below `bytes`' top box.
    private static func find(_ path: [String], in bytes: [UInt8]) -> Range<Int>? {
        var range = 8..<bytes.count
        for type in path {
            guard let child = children(bytes, in: range).first(where: { $0.type == type }) else { return nil }
            range = (child.range.lowerBound + 8)..<child.range.upperBound
        }
        return range
    }

    static func box(_ type: String, _ content: [UInt8]) -> [UInt8] {
        be32Bytes(UInt32(8 + content.count)) + Array(type.utf8) + content
    }

    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ content: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)] + content)
    }

    static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        return bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset >= 0, offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func be64Bytes(_ value: UInt64) -> [UInt8] {
        be32Bytes(UInt32(value >> 32)) + be32Bytes(UInt32(value & 0xFFFF_FFFF))
    }
}

/// One track of a progressive file, served as fragmented MP4 segments by
/// the loopback server while the file downloads (`ProgressiveMP4`).
actor RemuxedTrack {
    let track: ProgressiveMP4.Track
    let segments: [ProgressiveMP4.Segment]
    private let movie: ProgressiveMP4.Movie
    private let downloader: TrackDownloader

    init(movie: ProgressiveMP4.Movie, track: ProgressiveMP4.Track, downloader: TrackDownloader) {
        self.movie = movie
        self.track = track
        self.downloader = downloader
        segments = ProgressiveMP4.segments(of: track)
    }

    /// The media playlist: `<prefix>/init.mp4`, then `<prefix>/<n>.m4s`.
    nonisolated func playlist(prefix: String) -> String {
        let target = max(1, Int(ceil(segments.map(\.duration).max() ?? 1)))
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        out += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"\(prefix)/init.mp4\"\n"
        for (index, segment) in segments.enumerated() {
            out += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n\(prefix)/\(index).m4s\n"
        }
        return out + "#EXT-X-ENDLIST\n"
    }

    nonisolated var duration: Double { track.duration }

    /// `init.mp4` or `<n>.m4s`; nil for any other name.
    func resource(_ name: String) async throws -> Data? {
        if name == "init.mp4" { return ProgressiveMP4.initializationSegment(movie: movie, track: track) }
        guard name.hasSuffix(".m4s"), let index = Int(name.dropLast(4)), segments.indices.contains(index) else { return nil }
        let downloader = downloader
        return try await ProgressiveMP4.mediaSegment(track, segments[index], sequence: UInt32(index + 1)) { range in
            try await downloader.waitUntilAvailable(range)
            guard let data = try await downloader.read(range) else { throw ProgressiveMP4.Failure.malformed("cache lost bytes") }
            return data
        }
    }
}
