import Foundation

/// Serves a WebM (Matroska) file as fragmented MP4, the same way as
/// `ProgressiveMP4`: every on-demand video is an HLS presentation on every
/// platform, so subtitles attach as subtitle renditions whatever the source.
///
/// Nothing is re-encoded and no second copy is stored. The file's `Cues`
/// (its seek index) say where the clusters at each keyframe begin; a media
/// segment is a run of clusters whose blocks are rewritten as one `moof` +
/// `mdat`, read from the cached file as it downloads. A file without cues is
/// indexed by walking its cluster headers (which waits for the download).
///
/// VP9, VP8, AV1 and Opus have ISO-BMFF sample entries. Anything else (Vorbis
/// audio, encrypted or compressed tracks) fails with `unsupportedCodec`,
/// which names the format, never silently.
enum Matroska {
    enum Failure: Error, Equatable, LocalizedError {
        case notMatroska
        case malformed(String)
        /// The track's format cannot be carried in MP4 (named for the user).
        case unsupportedCodec(String)

        var errorDescription: String? {
            switch self {
            case .notMatroska: "The file is not WebM."
            case .malformed(let detail): "The WebM file is damaged (\(detail))."
            case .unsupportedCodec(let name):
                "This video uses \(name), which can't be played here. Choose another quality from the player's menu."
            }
        }
    }

    // MARK: element IDs

    enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let docType: UInt32 = 0x4282
        static let segment: UInt32 = 0x1853_8067
        static let seekHead: UInt32 = 0x114D_9B74
        static let seek: UInt32 = 0x4DBB
        static let seekID: UInt32 = 0x53AB
        static let seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549_A966
        static let timecodeScale: UInt32 = 0x2A_D7B1
        static let duration: UInt32 = 0x4489
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let codecDelay: UInt32 = 0x56AA
        static let defaultDuration: UInt32 = 0x23_E383
        static let contentEncodings: UInt32 = 0x6D80
        static let video: UInt32 = 0xE0
        static let pixelWidth: UInt32 = 0xB0
        static let pixelHeight: UInt32 = 0xBA
        static let colour: UInt32 = 0x55B0
        static let matrixCoefficients: UInt32 = 0x55B1
        static let range: UInt32 = 0x55B9
        static let transferCharacteristics: UInt32 = 0x55BA
        static let primaries: UInt32 = 0x55BB
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let cues: UInt32 = 0x1C53_BB6B
        static let cuePoint: UInt32 = 0xBB
        static let cueTime: UInt32 = 0xB3
        static let cueTrackPositions: UInt32 = 0xB7
        static let cueTrack: UInt32 = 0xF7
        static let cueClusterPosition: UInt32 = 0xF1
        static let cluster: UInt32 = 0x1F43_B675
        static let timestamp: UInt32 = 0xE7
        static let simpleBlock: UInt32 = 0xA3
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let blockDuration: UInt32 = 0x9B
        static let referenceBlock: UInt32 = 0xFB
    }

    // MARK: model

    struct Colour: Sendable, Equatable {
        var primaries: UInt8?
        var transfer: UInt8?
        var matrix: UInt8?
        /// 1: limited ("broadcast"), 2: full.
        var range: UInt8?
    }

    struct TrackInfo: Sendable, Equatable {
        var number: UInt64
        var kind: ProgressiveMP4.Kind
        var codecID: String
        var codecPrivate: [UInt8]
        var encoded: Bool
        var defaultDuration: UInt64?
        var codecDelay: UInt64
        var width: Int
        var height: Int
        var colour: Colour?
        var sampleRate: Double
        var channels: Int
    }

    /// A keyframe position: time in the file's timecode units, and the
    /// absolute file offset of the cluster holding it.
    struct CuePoint: Sendable, Equatable {
        var time: UInt64
        var track: UInt64?
        var clusterOffset: Int64
    }

    struct File: Sendable, Equatable {
        /// Nanoseconds per timecode unit.
        var timecodeScale: UInt64
        /// In timecode units.
        var duration: Double?
        var tracks: [TrackInfo]
        var cues: [CuePoint]
        /// Where the segment's data ends (the file's end for unknown sizes).
        var end: Int64

        func track(_ kind: ProgressiveMP4.Kind) -> TrackInfo? { tracks.first { $0.kind == kind } }
        var seconds: Double? { duration.map { $0 * Double(timecodeScale) / 1e9 } }
    }

    // MARK: EBML

    struct Element: Equatable {
        var id: UInt32
        /// Content bytes, relative to what was parsed.
        var data: Range<Int>
    }

    /// An ID (with its length marker) or a size (without; nil when unknown).
    static func vint(_ bytes: [UInt8], at offset: Int, keepMarker: Bool) -> (value: UInt64?, length: Int)? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard offset + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (0xFF >> length))
        var allOnes = value == UInt64(0xFF >> length)
        for index in 1..<length {
            value = value << 8 | UInt64(bytes[offset + index])
            if bytes[offset + index] != 0xFF { allOnes = false }
        }
        return (keepMarker || !allOnes ? value : nil, length)
    }

    /// One element header at `offset`: its ID, header length and content size
    /// (nil: unknown size).
    static func header(_ bytes: [UInt8], at offset: Int) -> (id: UInt32, headerLength: Int, size: UInt64?)? {
        guard let id = vint(bytes, at: offset, keepMarker: true), let idValue = id.value, id.length <= 4,
              let size = vint(bytes, at: offset + id.length, keepMarker: false) else { return nil }
        return (UInt32(idValue), id.length + size.length, size.value)
    }

    /// The child elements in `range` (an element of unknown size runs to the end).
    static func children(_ bytes: [UInt8], in range: Range<Int>) -> [Element] {
        var result: [Element] = []
        var offset = range.lowerBound
        while offset < range.upperBound, let head = header(bytes, at: offset) {
            let start = offset + head.headerLength
            let end = head.size.map { start + Int(clamping: $0) } ?? range.upperBound
            guard end <= range.upperBound, start <= end else { break }
            result.append(Element(id: head.id, data: start..<end))
            offset = end
        }
        return result
    }

    static func unsigned(_ bytes: [UInt8], _ range: Range<Int>) -> UInt64 {
        bytes[range].prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func float(_ bytes: [UInt8], _ range: Range<Int>) -> Double {
        switch range.count {
        case 4: Double(Float(bitPattern: UInt32(unsigned(bytes, range))))
        case 8: Double(bitPattern: unsigned(bytes, range))
        default: 0
        }
    }

    static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range].prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: opening

    /// Reads the headers, track list and seek index of a WebM file through
    /// `read` (which waits for the bytes).
    static func open(total: Int64, read: RemuxRead) async throws -> File {
        func bytes(_ range: Range<Int64>) async throws -> [UInt8] {
            [UInt8](try await read(range.clamped(to: 0..<total)))
        }
        func headerAt(_ offset: Int64) async throws -> (id: UInt32, headerLength: Int, size: UInt64?) {
            let head = try await bytes(offset..<(offset + 12))
            guard let parsed = header(head, at: 0) else { throw Failure.malformed("element header") }
            return parsed
        }
        guard total >= 4, try await bytes(0..<4) == ProgressiveMP4.be32Bytes(ID.ebml) else { throw Failure.notMatroska }
        let ebml = try await headerAt(0)
        guard ebml.id == ID.ebml, let ebmlSize = ebml.size else { throw Failure.notMatroska }
        let ebmlEnd = Int64(ebml.headerLength) + Int64(ebmlSize)
        let ebmlContent = try await bytes(Int64(ebml.headerLength)..<ebmlEnd)
        let docType = children(ebmlContent, in: 0..<ebmlContent.count).first { $0.id == ID.docType }
            .map { string(ebmlContent, $0.data) } ?? "matroska"
        guard docType == "webm" || docType == "matroska" else { throw Failure.notMatroska }

        let segment = try await headerAt(ebmlEnd)
        guard segment.id == ID.segment else { throw Failure.malformed("no segment") }
        let dataStart = ebmlEnd + Int64(segment.headerLength)
        let end = segment.size.map { min(total, dataStart + Int64($0)) } ?? total

        var timecodeScale: UInt64 = 1_000_000
        var duration: Double?
        var tracks: [TrackInfo]?
        var cues: [CuePoint]?
        var cuesOffset: Int64?
        var firstCluster: Int64?
        var offset = dataStart
        while offset < end {
            let head = try await headerAt(offset)
            let contentStart = offset + Int64(head.headerLength)
            guard let size = head.size else {
                if head.id == ID.cluster { firstCluster = firstCluster ?? offset }
                break
            }
            let contentEnd = contentStart + Int64(size)
            switch head.id {
            case ID.info:
                let content = try await bytes(contentStart..<contentEnd)
                for child in children(content, in: 0..<content.count) {
                    if child.id == ID.timecodeScale { timecodeScale = max(1, unsigned(content, child.data)) }
                    if child.id == ID.duration { duration = float(content, child.data) }
                }
            case ID.tracks:
                let content = try await bytes(contentStart..<contentEnd)
                tracks = parseTracks(content)
            case ID.seekHead:
                let content = try await bytes(contentStart..<contentEnd)
                cuesOffset = parseSeekHead(content, target: ID.cues).map { dataStart + Int64($0) }
            case ID.cues:
                let content = try await bytes(contentStart..<contentEnd)
                cues = parseCues(content, dataStart: dataStart)
            case ID.cluster:
                firstCluster = firstCluster ?? offset
            default:
                break
            }
            // Everything needed comes before the media, except cues stored
            // at the end, which the seek head points to.
            if firstCluster != nil, tracks != nil {
                if cues == nil, let cuesOffset {
                    let cuesHead = try await headerAt(cuesOffset)
                    if cuesHead.id == ID.cues, let cuesSize = cuesHead.size {
                        let start = cuesOffset + Int64(cuesHead.headerLength)
                        let content = try await bytes(start..<(start + Int64(cuesSize)))
                        cues = parseCues(content, dataStart: dataStart)
                    }
                }
                if cues != nil { break }
            }
            offset = contentEnd
        }
        guard let tracks, !tracks.isEmpty else { throw Failure.malformed("no tracks") }
        guard let firstCluster else { throw Failure.malformed("no clusters") }
        let index: [CuePoint]
        if let cues, !cues.isEmpty {
            index = cues
        } else {
            index = try await indexClusters(from: firstCluster, end: end, read: read)
        }
        return File(timecodeScale: timecodeScale, duration: duration, tracks: tracks, cues: index, end: end)
    }

    /// A file without cues: every cluster is a possible segment start.
    private static func indexClusters(from start: Int64, end: Int64, read: RemuxRead) async throws -> [CuePoint] {
        var points: [CuePoint] = []
        var offset = start
        while offset < end {
            let head = [UInt8](try await read(offset..<min(end, offset + 32)))
            guard let parsed = header(head, at: 0), let size = parsed.size else { break }
            if parsed.id == ID.cluster,
               let stamp = children(head, in: parsed.headerLength..<head.count).first(where: { $0.id == ID.timestamp }) {
                points.append(CuePoint(time: unsigned(head, stamp.data), track: nil, clusterOffset: offset))
            }
            offset += Int64(parsed.headerLength) + Int64(size)
        }
        guard !points.isEmpty else { throw Failure.malformed("no clusters") }
        return points
    }

    static func parseTracks(_ bytes: [UInt8]) -> [TrackInfo] {
        children(bytes, in: 0..<bytes.count).filter { $0.id == ID.trackEntry }.compactMap { entry in
            var info = TrackInfo(number: 0, kind: .other, codecID: "", codecPrivate: [], encoded: false,
                                 defaultDuration: nil, codecDelay: 0, width: 0, height: 0, colour: nil,
                                 sampleRate: 0, channels: 0)
            for child in children(bytes, in: entry.data) {
                switch child.id {
                case ID.trackNumber: info.number = unsigned(bytes, child.data)
                case ID.trackType:
                    let type = unsigned(bytes, child.data)
                    info.kind = type == 1 ? .video : type == 2 ? .audio : .other
                case ID.codecID: info.codecID = string(bytes, child.data)
                case ID.codecPrivate: info.codecPrivate = Array(bytes[child.data])
                case ID.codecDelay: info.codecDelay = unsigned(bytes, child.data)
                case ID.defaultDuration: info.defaultDuration = unsigned(bytes, child.data)
                case ID.contentEncodings: info.encoded = true
                case ID.video:
                    for field in children(bytes, in: child.data) {
                        switch field.id {
                        case ID.pixelWidth: info.width = Int(unsigned(bytes, field.data))
                        case ID.pixelHeight: info.height = Int(unsigned(bytes, field.data))
                        case ID.colour:
                            var colour = Colour()
                            for item in children(bytes, in: field.data) {
                                let value = UInt8(clamping: unsigned(bytes, item.data))
                                switch item.id {
                                case ID.primaries: colour.primaries = value
                                case ID.transferCharacteristics: colour.transfer = value
                                case ID.matrixCoefficients: colour.matrix = value
                                case ID.range: colour.range = value
                                default: break
                                }
                            }
                            info.colour = colour
                        default: break
                        }
                    }
                case ID.audio:
                    for field in children(bytes, in: child.data) {
                        if field.id == ID.samplingFrequency { info.sampleRate = float(bytes, field.data) }
                        if field.id == ID.channels { info.channels = Int(unsigned(bytes, field.data)) }
                    }
                default: break
                }
            }
            return info.number > 0 ? info : nil
        }
    }

    /// The position (relative to the segment's data) the seek head gives `target`.
    static func parseSeekHead(_ bytes: [UInt8], target: UInt32) -> UInt64? {
        for seek in children(bytes, in: 0..<bytes.count) where seek.id == ID.seek {
            var id: UInt32?
            var position: UInt64?
            for child in children(bytes, in: seek.data) {
                if child.id == ID.seekID { id = UInt32(truncatingIfNeeded: unsigned(bytes, child.data)) }
                if child.id == ID.seekPosition { position = unsigned(bytes, child.data) }
            }
            if id == target, let position { return position }
        }
        return nil
    }

    static func parseCues(_ bytes: [UInt8], dataStart: Int64) -> [CuePoint] {
        var points: [CuePoint] = []
        for point in children(bytes, in: 0..<bytes.count) where point.id == ID.cuePoint {
            var time: UInt64?
            for child in children(bytes, in: point.data) {
                if child.id == ID.cueTime { time = unsigned(bytes, child.data) }
            }
            guard let time else { continue }
            for child in children(bytes, in: point.data) where child.id == ID.cueTrackPositions {
                var track: UInt64?
                var position: UInt64?
                for field in children(bytes, in: child.data) {
                    if field.id == ID.cueTrack { track = unsigned(bytes, field.data) }
                    if field.id == ID.cueClusterPosition { position = unsigned(bytes, field.data) }
                }
                if let position { points.append(CuePoint(time: time, track: track, clusterOffset: dataStart + Int64(position))) }
            }
        }
        return points
    }

    // MARK: segments

    struct Segment: Sendable, Equatable {
        /// Start time, in timecode units.
        var start: UInt64
        /// The next segment's start (or the file's duration), in timecode units.
        var end: UInt64
        /// The clusters it spans.
        var bytes: Range<Int64>
    }

    /// Segments of about `target` seconds for `track`, each starting at a cue
    /// (a keyframe for video).
    static func segments(of file: File, track: TrackInfo, target: Double = 4) -> [Segment] {
        // A file indexed for another track (muxed WebM cues only the video)
        // still splits at those clusters.
        let own = file.cues.filter { $0.track == nil || $0.track == track.number }
        var seen = Set<Int64>()
        let points = (own.isEmpty ? file.cues : own)
            .sorted { $0.clusterOffset < $1.clusterOffset }
            .filter { seen.insert($0.clusterOffset).inserted }
        guard let first = points.first else { return [] }
        let targetUnits = UInt64(target * 1e9 / Double(file.timecodeScale))
        let fileEnd = file.duration.map { UInt64(max(0, $0.rounded(.up))) }
        var starts: [CuePoint] = [first]
        for point in points.dropFirst() where point.time >= starts[starts.count - 1].time + targetUnits {
            starts.append(point)
        }
        return starts.enumerated().map { index, point in
            let next = index + 1 < starts.count ? starts[index + 1] : nil
            let end = next?.time ?? max(fileEnd ?? point.time + targetUnits, point.time + 1)
            return Segment(start: point.time, end: end, bytes: point.clusterOffset..<(next?.clusterOffset ?? file.end))
        }
    }

    /// One frame of a track: where its bytes lie in the parsed range, and its
    /// presentation time in timecode units.
    struct Frame: Equatable {
        var data: Range<Int>
        var time: Int64
        var isKey: Bool
        var duration: UInt64?
    }

    /// The frames of `trackNumber` in the clusters of `bytes`, in file order.
    static func frames(in bytes: [UInt8], trackNumber: UInt64) throws -> [Frame] {
        var frames: [Frame] = []
        for cluster in children(bytes, in: 0..<bytes.count) where cluster.id == ID.cluster {
            let items = children(bytes, in: cluster.data)
            let base = Int64(items.first { $0.id == ID.timestamp }.map { unsigned(bytes, $0.data) } ?? 0)
            for item in items {
                switch item.id {
                case ID.simpleBlock:
                    try appendBlock(bytes, item.data, base: base, track: trackNumber, key: nil, duration: nil, to: &frames)
                case ID.blockGroup:
                    let parts = children(bytes, in: item.data)
                    guard let block = parts.first(where: { $0.id == ID.block }) else { continue }
                    let referenced = parts.contains { $0.id == ID.referenceBlock }
                    let duration = parts.first { $0.id == ID.blockDuration }.map { unsigned(bytes, $0.data) }
                    try appendBlock(bytes, block.data, base: base, track: trackNumber, key: !referenced,
                                    duration: duration, to: &frames)
                default: break
                }
            }
        }
        return frames
    }

    private static func appendBlock(_ bytes: [UInt8], _ range: Range<Int>, base: Int64, track: UInt64,
                                    key: Bool?, duration: UInt64?, to frames: inout [Frame]) throws {
        guard let number = vint(bytes, at: range.lowerBound, keepMarker: false), let trackNumber = number.value else {
            throw Failure.malformed("block track")
        }
        guard trackNumber == track else { return }
        var offset = range.lowerBound + number.length
        guard offset + 3 <= range.upperBound else { throw Failure.malformed("block header") }
        let relative = Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
        let flags = bytes[offset + 2]
        offset += 3
        let time = base + Int64(relative)
        let isKey = key ?? (flags & 0x80 != 0)
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 {
            frames.append(Frame(data: offset..<range.upperBound, time: time, isKey: isKey, duration: duration))
            return
        }
        // Laced: several frames in one block (audio); all but the first are
        // timed by the duration pass.
        guard offset < range.upperBound else { throw Failure.malformed("lace count") }
        let count = Int(bytes[offset]) + 1
        offset += 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                while true {
                    guard offset < range.upperBound else { throw Failure.malformed("xiph lace") }
                    let byte = Int(bytes[offset]); offset += 1
                    size += byte
                    if byte != 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML
            guard let first = vint(bytes, at: offset, keepMarker: false), let firstSize = first.value else {
                throw Failure.malformed("ebml lace")
            }
            offset += first.length
            sizes.append(Int(firstSize))
            for _ in 1..<max(1, count - 1) {
                guard let delta = vint(bytes, at: offset, keepMarker: false), let raw = delta.value else {
                    throw Failure.malformed("ebml lace delta")
                }
                offset += delta.length
                let bias = (Int64(1) << (7 * delta.length - 1)) - 1
                sizes.append(sizes[sizes.count - 1] + Int(Int64(raw) - bias))
            }
        default: // fixed
            let each = (range.upperBound - offset) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, +)
        sizes.append(range.upperBound - offset - used)
        guard sizes.allSatisfy({ $0 >= 0 }) else { throw Failure.malformed("lace sizes") }
        for (index, size) in sizes.enumerated() {
            frames.append(Frame(data: offset..<(offset + size), time: time, isKey: isKey,
                                duration: index == 0 ? duration : nil))
            offset += size
        }
    }

    // MARK: sample entries

    /// What the init segment's sample description needs, and the codec string.
    struct SampleDescription: Sendable, Equatable {
        var entry: [UInt8]
        var codecs: String
    }

    /// The display name of a format the MP4 path cannot carry.
    static func unsupportedName(_ codecID: String) -> String {
        switch codecID {
        case "A_VORBIS": "Vorbis audio"
        case "V_THEORA": "Theora video"
        case "A_FLAC": "FLAC audio in WebM"
        default: codecID.isEmpty ? "an unknown format" : codecID
        }
    }

    /// The sample entry for `track`; `firstFrame` is a keyframe of the track
    /// (VP8/VP9 keep their profile and bit depth only there).
    static func sampleDescription(_ track: TrackInfo, firstFrame: [UInt8]) throws -> SampleDescription {
        guard !track.encoded else { throw Failure.unsupportedCodec("an encrypted or compressed WebM track") }
        switch track.codecID {
        case "V_VP9", "V_VP8":
            let isVP9 = track.codecID == "V_VP9"
            let header = isVP9 ? VP9Header(firstFrame) : nil
            let profile = header?.profile ?? 0
            let bitDepth = header?.bitDepth ?? 8
            let level = vpLevel(width: track.width, height: track.height)
            let colour = track.colour
            let fallback = header.map { vpColour(colourSpace: $0.colourSpace) } ?? (1, 1, 1)
            let primaries = colour?.primaries ?? fallback.0
            let transfer = colour?.transfer ?? fallback.1
            let matrix = colour?.matrix ?? fallback.2
            let fullRange: UInt8 = colour?.range == 2 || header?.fullRange == true ? 1 : 0
            let chroma = header?.chroma ?? 1
            let config = ProgressiveMP4.fullBox("vpcC", version: 1, flags: 0,
                                                [profile, level, bitDepth << 4 | chroma << 1 | fullRange,
                                                 primaries, transfer, matrix, 0, 0])
            let fourCC = isVP9 ? "vp09" : "vp08"
            let codecs = "\(fourCC).\(twoDigits(profile)).\(twoDigits(level)).\(twoDigits(bitDepth))"
            return SampleDescription(entry: visualEntry(fourCC, track: track, config: config), codecs: codecs)
        case "V_AV1":
            // WebM's CodecPrivate for AV1 is the `av1C` record itself.
            let record = track.codecPrivate
            guard record.count >= 4, record[0] & 0x80 != 0 else { throw Failure.malformed("AV1 configuration") }
            let profile = record[1] >> 5
            let level = record[1] & 0x1F
            let tier = record[2] >> 7 == 1 ? "H" : "M"
            let bitDepth = record[2] & 0x40 == 0 ? 8 : (record[2] & 0x20 == 0 ? 10 : 12)
            let codecs = "av01.\(profile).\(twoDigits(level))\(tier).\(twoDigits(UInt8(bitDepth)))"
            return SampleDescription(entry: visualEntry("av01", track: track, config: ProgressiveMP4.box("av1C", record)),
                                     codecs: codecs)
        case "A_OPUS":
            return SampleDescription(entry: audioEntry("Opus", track: track, sampleRate: 48_000, config: opusConfig(track)),
                                     codecs: "opus")
        default:
            throw Failure.unsupportedCodec(unsupportedName(track.codecID))
        }
    }

    static func twoDigits(_ value: UInt8) -> String { value < 10 ? "0\(value)" : "\(value)" }

    /// `dOps` from WebM's `OpusHead` (little-endian) or, without one, from the track.
    static func opusConfig(_ track: TrackInfo) -> [UInt8] {
        let head = track.codecPrivate
        var content: [UInt8]
        if head.count >= 19, String(decoding: head[0..<8], as: UTF8.self) == "OpusHead" {
            let channels = head[9]
            let preSkip = UInt16(head[10]) | UInt16(head[11]) << 8
            let rate = UInt32(head[12]) | UInt32(head[13]) << 8 | UInt32(head[14]) << 16 | UInt32(head[15]) << 24
            let gain = UInt16(head[16]) | UInt16(head[17]) << 8
            let family = head[18]
            content = [0, channels, UInt8(preSkip >> 8), UInt8(preSkip & 0xFF)] + ProgressiveMP4.be32Bytes(rate)
                + [UInt8(gain >> 8), UInt8(gain & 0xFF), family]
            if family != 0, head.count >= 21 + Int(channels) {
                content += Array(head[19..<(21 + Int(channels))])
            }
        } else {
            let channels = UInt8(clamping: max(1, track.channels))
            let preSkip = UInt16(clamping: track.codecDelay * 48_000 / 1_000_000_000)
            content = [0, channels, UInt8(preSkip >> 8), UInt8(preSkip & 0xFF)] + ProgressiveMP4.be32Bytes(48_000) + [0, 0, 0]
        }
        return ProgressiveMP4.box("dOps", content)
    }

    private static func visualEntry(_ type: String, track: TrackInfo, config: [UInt8]) -> [UInt8] {
        var content = [UInt8](repeating: 0, count: 6) + [0, 1]           // reserved, data_reference_index
        content += [UInt8](repeating: 0, count: 16)                      // pre_defined, reserved
        content += [UInt8(track.width >> 8 & 0xFF), UInt8(track.width & 0xFF),
                    UInt8(track.height >> 8 & 0xFF), UInt8(track.height & 0xFF)]
        content += ProgressiveMP4.be32Bytes(0x0048_0000) + ProgressiveMP4.be32Bytes(0x0048_0000)
        content += ProgressiveMP4.be32Bytes(0) + [0, 1]                  // reserved, frame_count
        content += [UInt8](repeating: 0, count: 32)                      // compressorname
        content += [0x00, 0x18, 0xFF, 0xFF]                              // depth, pre_defined
        return ProgressiveMP4.box(type, content + config)
    }

    private static func audioEntry(_ type: String, track: TrackInfo, sampleRate: UInt32, config: [UInt8]) -> [UInt8] {
        let channels = UInt16(clamping: max(1, track.channels))
        var content = [UInt8](repeating: 0, count: 6) + [0, 1]
        content += [UInt8](repeating: 0, count: 8)
        content += [UInt8(channels >> 8), UInt8(channels & 0xFF), 0, 16, 0, 0, 0, 0]
        content += ProgressiveMP4.be32Bytes(sampleRate << 16)
        return ProgressiveMP4.box(type, content + config)
    }

    /// The VP9 level for a picture size (Annex A of the VP9 codec ISO mapping),
    /// assuming up to 60 frames per second.
    static func vpLevel(width: Int, height: Int) -> UInt8 {
        let size = width * height
        return switch size {
        case ...36_864: 10
        case ...73_728: 11
        case ...122_880: 20
        case ...245_760: 21
        case ...552_960: 30
        case ...983_040: 31
        case ...2_228_224: 41
        case ...8_912_896: 51
        default: 61
        }
    }

    /// Colour primaries, transfer and matrix (ISO/IEC 23091-2) for a VP9 colour space.
    static func vpColour(colourSpace: UInt8) -> (UInt8, UInt8, UInt8) {
        switch colourSpace {
        case 1, 3: (6, 6, 6)       // BT.601, SMPTE 170
        case 4: (7, 7, 7)          // SMPTE 240
        case 5: (9, 14, 9)         // BT.2020
        case 7: (1, 13, 0)         // sRGB
        default: (1, 1, 1)         // BT.709 (also the usual unspecified case)
        }
    }

    /// The fields of a VP9 keyframe's uncompressed header the `vpcC` needs.
    struct VP9Header: Equatable {
        var profile: UInt8
        var bitDepth: UInt8
        var colourSpace: UInt8
        var fullRange: Bool
        /// `vpcC` chroma subsampling: 1 (4:2:0), 2 (4:2:2), 3 (4:4:4).
        var chroma: UInt8

        init?(_ frame: [UInt8]) {
            var reader = BitReader(frame)
            guard reader.read(2) == 2 else { return nil }
            let low = reader.read(1), high = reader.read(1)
            profile = UInt8(high << 1 | low)
            if profile == 3 { _ = reader.read(1) }
            guard reader.read(1) == 0, reader.read(1) == 0 else { return nil } // shows an existing frame / not a keyframe
            _ = reader.read(2) // show_frame, error_resilient_mode
            guard reader.read(24) == 0x49_8342 else { return nil }
            bitDepth = profile >= 2 ? (reader.read(1) == 1 ? 12 : 10) : 8
            colourSpace = UInt8(reader.read(3))
            if colourSpace != 7 {
                fullRange = reader.read(1) == 1
                if profile == 1 || profile == 3 {
                    let x = reader.read(1), y = reader.read(1)
                    chroma = x == 1 && y == 1 ? 1 : x == 1 ? 2 : 3
                } else {
                    chroma = 1
                }
            } else {
                fullRange = true
                chroma = 3
            }
            guard !reader.exhausted else { return nil }
        }
    }

    struct BitReader {
        let bytes: [UInt8]
        var position = 0
        var exhausted = false
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                let byte = position / 8
                guard byte < bytes.count else { exhausted = true; return value << 1 }
                value = value << 1 | Int(bytes[byte] >> (7 - UInt8(position % 8)) & 1)
                position += 1
            }
            return value
        }
    }

    // MARK: writing

    static func initializationSegment(file: File, track: TrackInfo, description: SampleDescription, timescale: UInt32) -> Data {
        typealias M = ProgressiveMP4
        let unityValues: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]
        let unity: [UInt8] = unityValues.flatMap { M.be32Bytes($0) }
        let fileType = M.box("ftyp", Array("iso6".utf8) + M.be32Bytes(0) + Array("iso6isommp41".utf8))
        var movieHeaderContent = M.be32Bytes(0) + M.be32Bytes(0) + M.be32Bytes(timescale) + M.be32Bytes(0)
        movieHeaderContent += M.be32Bytes(0x0001_0000) + [0x01, 0x00] + [UInt8](repeating: 0, count: 10)
        movieHeaderContent += unity + [UInt8](repeating: 0, count: 24) + M.be32Bytes(2)
        let movieHeader = M.fullBox("mvhd", version: 0, flags: 0, movieHeaderContent)
        let isVideo = track.kind == .video
        let volume: [UInt8] = isVideo ? [0, 0] : [0x01, 0x00]
        var trackHeaderContent = M.be32Bytes(0) + M.be32Bytes(0) + M.be32Bytes(1) + M.be32Bytes(0) + M.be32Bytes(0)
        trackHeaderContent += [UInt8](repeating: 0, count: 12) + volume + [0, 0] + unity
        trackHeaderContent += M.be32Bytes(UInt32(isVideo ? track.width : 0) << 16)
        trackHeaderContent += M.be32Bytes(UInt32(isVideo ? track.height : 0) << 16)
        let trackHeader = M.fullBox("tkhd", version: 0, flags: 3, trackHeaderContent)
        let mediaHeader = M.fullBox("mdhd", version: 0, flags: 0,
                                    M.be32Bytes(0) + M.be32Bytes(0) + M.be32Bytes(timescale) + M.be32Bytes(0) + [0x55, 0xC4, 0, 0])
        let handler = M.fullBox("hdlr", version: 0, flags: 0,
                                M.be32Bytes(0) + Array((isVideo ? "vide" : "soun").utf8) + [UInt8](repeating: 0, count: 12)
                                    + Array((isVideo ? "VideoHandler" : "SoundHandler").utf8) + [0])
        let mediaInformationHeader = isVideo
            ? M.fullBox("vmhd", version: 0, flags: 1, [UInt8](repeating: 0, count: 8))
            : M.fullBox("smhd", version: 0, flags: 0, [0, 0, 0, 0])
        let dataInformation = M.box("dinf", M.fullBox("dref", version: 0, flags: 0,
                                                      M.be32Bytes(1) + M.fullBox("url ", version: 0, flags: 1, [])))
        let sampleTable = M.box("stbl",
                                M.fullBox("stsd", version: 0, flags: 0, M.be32Bytes(1) + description.entry)
                                    + M.fullBox("stts", version: 0, flags: 0, M.be32Bytes(0))
                                    + M.fullBox("stsc", version: 0, flags: 0, M.be32Bytes(0))
                                    + M.fullBox("stsz", version: 0, flags: 0, M.be32Bytes(0) + M.be32Bytes(0))
                                    + M.fullBox("stco", version: 0, flags: 0, M.be32Bytes(0)))
        let media = M.box("mdia", mediaHeader + handler + M.box("minf", mediaInformationHeader + dataInformation + sampleTable))
        let movieExtends = M.box("mvex", M.fullBox("trex", version: 0, flags: 0,
                                                   M.be32Bytes(1) + M.be32Bytes(1) + M.be32Bytes(0) + M.be32Bytes(0) + M.be32Bytes(0)))
        return Data(fileType + M.box("moov", movieHeader + M.box("trak", trackHeader + media) + movieExtends))
    }

    /// The MP4 timescale for a file's timecode units (exact when they divide a second).
    static func timescale(for timecodeScale: UInt64) -> UInt32 {
        let perSecond = 1_000_000_000 / timecodeScale
        return 1_000_000_000 % timecodeScale == 0 && perSecond <= UInt64(UInt32.max) ? UInt32(perSecond) : 1_000_000
    }

    /// One media segment: the segment's frames as fragmented MP4.
    static func mediaSegment(file: File, track: TrackInfo, segment: Segment, sequence: UInt32,
                             read: RemuxRead) async throws -> Data {
        let bytes = [UInt8](try await read(segment.bytes))
        guard Int64(bytes.count) == Int64(segment.bytes.count) else { throw Failure.malformed("short cluster read") }
        let frames = try Self.frames(in: bytes, trackNumber: track.number)
        let scale = timescale(for: file.timecodeScale)
        let toTicks = { (units: Int64) -> Int64 in
            Int64((Double(units) * Double(file.timecodeScale) * Double(scale) / 1e9).rounded())
        }
        let defaultTicks = track.defaultDuration.map { Int64((Double($0) * Double(scale) / 1e9).rounded()) }
        var samples: [ProgressiveMP4.Sample] = []
        var payload = Data()
        payload.reserveCapacity(bytes.count)
        let startTicks = toTicks(frames.first?.time ?? Int64(segment.start))
        let endTicks = toTicks(Int64(segment.end))
        // Laced frames share their block's time: spread them by the default
        // duration, or evenly up to the next block.
        var times = frames.map { toTicks($0.time) }
        var index = 0
        while index < frames.count {
            var next = index + 1
            while next < frames.count, frames[next].time == frames[index].time { next += 1 }
            let count = next - index
            if count > 1 {
                let following = next < frames.count ? times[next] : max(endTicks, times[index] + Int64(count))
                let step = defaultTicks ?? max(1, (following - times[index]) / Int64(count))
                for lace in 1..<count { times[index + lace] = times[index] + step * Int64(lace) }
            }
            index = next
        }
        for (position, frame) in frames.enumerated() {
            let time = times[position]
            let following: Int64 = if position + 1 < frames.count {
                times[position + 1]
            } else if let duration = frame.duration {
                time + toTicks(Int64(duration))
            } else {
                max(endTicks, time + (defaultTicks ?? 1))
            }
            samples.append(ProgressiveMP4.Sample(offset: 0, size: frame.data.count,
                                                 duration: UInt32(clamping: max(1, following - time)),
                                                 compositionOffset: 0,
                                                 isSync: track.kind != .video || frame.isKey))
            payload.append(contentsOf: bytes[frame.data])
        }
        let header = ProgressiveMP4.fragmentHeader(trackID: 1, decodeTime: UInt64(max(0, startTicks)), samples: samples,
                                                   sequence: sequence, payloadSize: payload.count)
        return Data(header) + payload
    }
}

/// One track of a WebM file (`Matroska`).
struct WebMRemuxSource: RemuxSource {
    let file: Matroska.File
    let track: Matroska.TrackInfo
    let segments: [Matroska.Segment]
    let description: Matroska.SampleDescription

    /// Checks that the track can be carried in MP4 (reading its first
    /// keyframe for VP8/VP9), so an unsupported format fails here with its
    /// name instead of as a player error later.
    static func make(file: Matroska.File, track: Matroska.TrackInfo, read: RemuxRead) async throws -> WebMRemuxSource {
        let segments = Matroska.segments(of: file, track: track)
        guard let first = segments.first else { throw Matroska.Failure.malformed("no cues for the track") }
        var keyframe: [UInt8] = []
        if track.codecID == "V_VP9" || track.codecID == "V_VP8" {
            let bytes = [UInt8](try await read(first.bytes))
            if let frame = try Matroska.frames(in: bytes, trackNumber: track.number).first(where: \.isKey) {
                keyframe = Array(bytes[frame.data])
            }
        }
        let description = try Matroska.sampleDescription(track, firstFrame: keyframe)
        return WebMRemuxSource(file: file, track: track, segments: segments, description: description)
    }

    var segmentDurations: [Double] {
        let seconds = Double(file.timecodeScale) / 1e9
        return segments.map { $0.end > $0.start ? Double($0.end - $0.start) * seconds : 0 }
    }
    var duration: Double { file.seconds ?? segmentDurations.reduce(0, +) }
    var width: Int { track.width }
    var height: Int { track.height }
    var codecs: String? { description.codecs }

    func initializationSegment(read: RemuxRead) async throws -> Data {
        Matroska.initializationSegment(file: file, track: track, description: description,
                                       timescale: Matroska.timescale(for: file.timecodeScale))
    }

    func mediaSegment(_ index: Int, read: RemuxRead) async throws -> Data {
        try await Matroska.mediaSegment(file: file, track: track, segment: segments[index],
                                        sequence: UInt32(index + 1), read: read)
    }
}

/// Human names for formats, for messages that tell the user what failed.
enum MediaFormatNames {
    static func describe(codec: String, container: String) -> String {
        let lower = codec.lowercased()
        let name: String? = switch true {
        case lower.hasPrefix("vp09"), lower == "vp9": "VP9 video"
        case lower.hasPrefix("vp08"), lower == "vp8": "VP8 video"
        case lower.hasPrefix("av01"), lower == "av1": "AV1 video"
        case lower.hasPrefix("avc1"), lower.hasPrefix("avc3"), lower == "h264": "H.264 video"
        case lower.hasPrefix("hvc1"), lower.hasPrefix("hev1"), lower == "hevc": "HEVC video"
        case lower.hasPrefix("dvh1"), lower.hasPrefix("dvhe"): "Dolby Vision video"
        default: nil
        }
        if let name { return name }
        if !codec.isEmpty { return codec }
        return container.isEmpty ? "this format" : container
    }
}
