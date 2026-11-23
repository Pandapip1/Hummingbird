import Foundation

/// Reads the layout of a fragmented MP4 (DASH on-demand profile) file from
/// its first bytes: `ftyp` + `moov` (the initialization segment), then a
/// `sidx` box listing every media segment's size and duration.
///
/// That layout lets the media cache serve the file as an HLS presentation
/// with byte-range segments, so the player starts after the initialization
/// segment and the first media segment are local instead of scanning the
/// whole file.
enum FragmentedMP4 {
    struct Layout: Sendable, Equatable {
        /// `ftyp` + `moov`.
        var initialization: Range<Int64>
        var timeline: MediaSegmentTimeline
    }

    enum Probe: Sendable, Equatable {
        /// More bytes are needed, from the file start up to `upTo`.
        case needBytes(upTo: Int64)
        case layout(Layout)
        /// Not a fragmented MP4 with a segment index.
        case notIndexed
    }

    /// Inspects `data`, the file's first bytes. `indexHint` is the plugin's
    /// declared `sidx` range when it has one.
    static func probe(_ data: Data, indexHint: ClosedRange<Int64>? = nil) -> Probe {
        var offset: Int64 = 0
        var moovEnd: Int64?
        var fragmented = false
        let available = Int64(data.count)
        while offset + 8 <= available {
            guard let header = boxHeader(in: data, at: offset) else { return .notIndexed }
            let end = offset + header.size
            switch header.type {
            case "moov":
                guard end <= available else { return .needBytes(upTo: end) }
                moovEnd = end
                fragmented = containsChild("mvex", in: data, from: offset + header.headerSize, to: end)
            case "sidx":
                guard let moovEnd, fragmented else { return .notIndexed }
                guard end <= available else { return .needBytes(upTo: end) }
                guard let timeline = parseSegmentIndex(in: data, boxStart: offset, boxEnd: end,
                                                       initialization: 0..<moovEnd) else { return .notIndexed }
                return .layout(Layout(initialization: 0..<moovEnd, timeline: timeline))
            case "moof", "mdat":
                // Media before any index: not an indexed file.
                return .notIndexed
            default:
                break
            }
            guard header.size > 0 else { return .notIndexed }
            offset = end
        }
        if let indexHint, indexHint.upperBound + 1 > available { return .needBytes(upTo: indexHint.upperBound + 1) }
        // The next box header lies beyond what we have.
        return offset < 64 * 1_024 * 1_024 ? .needBytes(upTo: max(offset + 4_096, available * 2)) : .notIndexed
    }

    private struct BoxHeader { var type: String; var size: Int64; var headerSize: Int64 }

    private static func boxHeader(in data: Data, at offset: Int64) -> BoxHeader? {
        guard let size32 = readUInt32(data, offset), let typeBytes = bytes(data, offset + 4, 4) else { return nil }
        let type = String(decoding: typeBytes, as: UTF8.self)
        if size32 == 1 {
            guard let size64 = readUInt64(data, offset + 8), size64 >= 16, size64 <= UInt64(Int64.max) else { return nil }
            return BoxHeader(type: type, size: Int64(size64), headerSize: 16)
        }
        // A zero size ("to end of file") never precedes the index.
        guard size32 >= 8 else { return nil }
        return BoxHeader(type: type, size: Int64(size32), headerSize: 8)
    }

    private static func containsChild(_ type: String, in data: Data, from start: Int64, to end: Int64) -> Bool {
        var offset = start
        while offset + 8 <= end {
            guard let header = boxHeader(in: data, at: offset) else { return false }
            if header.type == type { return true }
            offset += header.size
        }
        return false
    }

    /// ISO/IEC 14496-12 §8.16.3. Segment offsets are relative to the first
    /// byte after the `sidx` box, plus `first_offset`.
    static func parseSegmentIndex(in data: Data, boxStart: Int64, boxEnd: Int64,
                                  initialization: Range<Int64>) -> MediaSegmentTimeline? {
        var cursor = boxStart + 8
        guard let versionAndFlags = readUInt32(data, cursor) else { return nil }
        let version = versionAndFlags >> 24
        cursor += 4 + 4 // reference_ID
        guard let timescale = readUInt32(data, cursor), timescale > 0 else { return nil }
        cursor += 4
        let earliest: UInt64
        let firstOffset: UInt64
        if version == 0 {
            guard let e = readUInt32(data, cursor), let f = readUInt32(data, cursor + 4) else { return nil }
            earliest = UInt64(e); firstOffset = UInt64(f); cursor += 8
        } else {
            guard let e = readUInt64(data, cursor), let f = readUInt64(data, cursor + 8) else { return nil }
            earliest = e; firstOffset = f; cursor += 16
        }
        cursor += 2 // reserved
        guard let countBytes = bytes(data, cursor, 2) else { return nil }
        let count = Int(countBytes[0]) << 8 | Int(countBytes[1])
        cursor += 2
        guard count > 0, cursor + Int64(count) * 12 <= boxEnd else { return nil }
        var byteOffset = boxEnd + Int64(firstOffset)
        var time = Double(earliest) / Double(timescale)
        var segments: [MediaSegmentTimeline.Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            guard let reference = readUInt32(data, cursor), let duration = readUInt32(data, cursor + 4) else { return nil }
            cursor += 12
            // A hierarchical index (reference_type 1) is not used by DASH on-demand files.
            guard reference & 0x8000_0000 == 0 else { return nil }
            let size = Int64(reference & 0x7FFF_FFFF)
            guard size > 0 else { return nil }
            let seconds = Double(duration) / Double(timescale)
            segments.append(.init(bytes: byteOffset..<(byteOffset + size), start: time, duration: seconds))
            byteOffset += size
            time += seconds
        }
        return MediaSegmentTimeline(initialization: initialization, segments: segments)
    }

    private static func bytes(_ data: Data, _ offset: Int64, _ count: Int) -> [UInt8]? {
        guard offset >= 0, offset + Int64(count) <= Int64(data.count) else { return nil }
        let start = data.startIndex + Int(offset)
        return Array(data[start..<(start + count)])
    }

    private static func readUInt32(_ data: Data, _ offset: Int64) -> UInt32? {
        guard let b = bytes(data, offset, 4) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int64) -> UInt64? {
        guard let b = bytes(data, offset, 8) else { return nil }
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// HLS playlists for fragmented MP4 tracks served from the media cache as
/// byte-range segments of one local file per track.
enum CachedHLS {
    struct Track: Sendable {
        var role: MediaTrackRole
        var layout: FragmentedMP4.Layout
        /// Path of the track's file relative to the presentation base.
        var fileName: String
        var playlistName: String
        var codec: String
        var bandwidth: Int
        var width: Int
        var height: Int

        var entry: MasterEntry {
            MasterEntry(playlistName: playlistName, codec: codec, bandwidth: bandwidth, width: width, height: height)
        }
    }

    static func mediaPlaylist(_ track: Track) -> String {
        let segments = track.layout.timeline.segments
        let target = max(1, Int(ceil(segments.map(\.duration).max() ?? 1)))
        let initialization = track.layout.initialization
        var result = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        result += "#EXT-X-MAP:URI=\"\(track.fileName)\",BYTERANGE=\"\(initialization.count)@\(initialization.lowerBound)\"\n"
        for segment in segments {
            result += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n"
            result += "#EXT-X-BYTERANGE:\(segment.bytes.count)@\(segment.bytes.lowerBound)\n\(track.fileName)\n"
        }
        return result + "#EXT-X-ENDLIST\n"
    }

    /// A master playlist pairing a video track with an optional separate
    /// audio rendition (named, with its language and characteristics, by
    /// `audioRendition`), plus subtitle renditions with their playlists.
    static func masterPlaylist(video: Track, audio: Track?, audioRendition: HLSPlaylist.Rendition? = nil,
                               subtitles: [(HLSPlaylist.Rendition, String)] = []) -> String {
        masterPlaylist(video: video.entry, audio: audio?.entry, audioRendition: audioRendition, subtitles: subtitles)
    }

    /// What a master playlist says about one track's media playlist.
    struct MasterEntry: Sendable {
        var playlistName: String
        var codec: String
        var bandwidth: Int
        var width: Int
        var height: Int
    }

    static func masterPlaylist(video: MasterEntry, audio: MasterEntry?, audioRendition: HLSPlaylist.Rendition? = nil,
                               subtitles: [(HLSPlaylist.Rendition, String)] = []) -> String {
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        if let audio {
            var rendition = audioRendition ?? HLSPlaylist.Rendition(groupID: "audio", name: "Audio", language: nil, isDefault: true, uri: nil)
            rendition.isDefault = true
            rendition.autoselect = true
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",\(rendition.attributes(uri: audio.playlistName))\n"
        }
        let legible = HLSPlaylist.legibleRenditions(subtitles: subtitles)
        master += legible.lines
        let codecs = [video.codec, audio?.codec ?? ""].filter { !$0.isEmpty }
        let bandwidth = max(1, video.bandwidth + (audio?.bandwidth ?? 0))
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)"
        // A partial CODECS list makes AVFoundation reject the variant; omit it
        // unless every track declares its codec.
        if codecs.count == (audio == nil ? 1 : 2) { master += ",CODECS=\"\(codecs.joined(separator: ","))\"" }
        if video.width > 0, video.height > 0 { master += ",RESOLUTION=\(video.width)x\(video.height)" }
        if audio != nil { master += ",AUDIO=\"audio\"" }
        return master + legible.variantAttributes + "\n\(video.playlistName)\n"
    }
}
