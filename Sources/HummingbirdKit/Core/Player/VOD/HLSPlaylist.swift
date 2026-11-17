import Foundation

/// Just enough of HLS (RFC 8216) to download an on-demand presentation into
/// the media cache and serve it back with local URIs.
enum HLSPlaylist {
    struct Variant: Sendable, Equatable {
        var uri: URL
        var bandwidth: Int
        var width: Int
        var height: Int
        var codecs: String
        var audioGroup: String?
        var attributes: String
    }

    struct Rendition: Sendable, Equatable {
        var groupID: String
        var name: String
        var language: String?
        var isDefault: Bool
        var uri: URL?
    }

    struct Master: Sendable, Equatable {
        var variants: [Variant]
        var audio: [Rendition]
    }

    /// One fetchable object of a media playlist: the initialization map, a
    /// key, or a segment.
    struct Resource: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case map, key, segment }
        var kind: Kind
        var uri: URL
        /// `EXT-X-BYTERANGE` / `BYTERANGE` within `uri`.
        var byteRange: Range<Int64>?
    }

    struct Segment: Sendable, Equatable {
        /// Index into `Media.resources`.
        var resource: Int
        var duration: Double
        /// The `EXT-X-MAP` and `EXT-X-KEY` resources in effect (indices).
        var map: Int?
        var key: Int?
        /// The key line's other attributes (METHOD, IV, KEYFORMAT…), verbatim.
        var keyAttributes: String?
        /// `EXT-X-DISCONTINUITY` before this segment (ad breaks, encoder changes).
        var discontinuity = false
        /// `EXT-X-PROGRAM-DATE-TIME`, verbatim, when given.
        var programDateTime: String?
    }

    struct Media: Sendable, Equatable {
        var targetDuration: Int
        var mediaSequence: Int
        var isEndless: Bool
        var resources: [Resource]
        var segments: [Segment]

        var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notAPlaylist
        case live
        case protected(String)
        var errorDescription: String? {
            switch self {
            case .notAPlaylist: "The stream's playlist could not be read."
            case .live: "This stream is live and cannot be downloaded ahead."
            case .protected(let method): "This stream is protected (\(method)) and cannot be played."
            }
        }
    }

    static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    static func parseMaster(_ text: String, base: URL) throws -> Master {
        guard text.hasPrefix("#EXTM3U") else { throw Failure.notAPlaylist }
        var variants: [Variant] = []
        var audio: [Rendition] = []
        var pending: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attributes = String(line.dropFirst("#EXT-X-MEDIA:".count))
                guard attribute("TYPE", in: attributes) == "AUDIO", let group = attribute("GROUP-ID", in: attributes) else { continue }
                audio.append(Rendition(groupID: group, name: attribute("NAME", in: attributes) ?? "",
                                       language: attribute("LANGUAGE", in: attributes),
                                       isDefault: attribute("DEFAULT", in: attributes) == "YES",
                                       uri: attribute("URI", in: attributes).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }))
            } else if let attributes = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                let resolution = attribute("RESOLUTION", in: attributes)?.split(separator: "x").compactMap { Int($0) } ?? []
                variants.append(Variant(uri: uri, bandwidth: Int(attribute("BANDWIDTH", in: attributes) ?? "") ?? 0,
                                        width: resolution.first ?? 0, height: resolution.count > 1 ? resolution[1] : 0,
                                        codecs: attribute("CODECS", in: attributes) ?? "",
                                        audioGroup: attribute("AUDIO", in: attributes), attributes: attributes))
            }
        }
        guard !variants.isEmpty else { throw Failure.notAPlaylist }
        return Master(variants: variants, audio: audio)
    }

    static func parseMedia(_ text: String, base: URL) throws -> Media {
        guard text.hasPrefix("#EXTM3U") else { throw Failure.notAPlaylist }
        var media = Media(targetDuration: 1, mediaSequence: 0, isEndless: true, resources: [], segments: [])
        var duration: Double?
        var byteRange: (length: Int64, offset: Int64?)?
        var lastRangeEnd: [URL: Int64] = [:]
        var map: Int?
        var key: Int?
        var keyAttributes: String?
        var isVOD = false
        var discontinuity = false
        var programDateTime: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                media.targetDuration = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 1
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                media.mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line == "#EXT-X-ENDLIST" || line == "#EXT-X-PLAYLIST-TYPE:VOD" {
                isVOD = true
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                programDateTime = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "")
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                byteRange = parseByteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = String(line.dropFirst("#EXT-X-MAP:".count))
                guard let uri = attribute("URI", in: attributes).flatMap({ URL(string: $0, relativeTo: base)?.absoluteURL }) else { continue }
                let range = attribute("BYTERANGE", in: attributes).flatMap(parseByteRange).map { r in
                    (r.offset ?? 0)..<((r.offset ?? 0) + r.length)
                }
                media.resources.append(Resource(kind: .map, uri: uri, byteRange: range))
                map = media.resources.count - 1
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = String(line.dropFirst("#EXT-X-KEY:".count))
                let method = attribute("METHOD", in: attributes) ?? "NONE"
                switch method {
                case "NONE":
                    key = nil
                    keyAttributes = nil
                case "AES-128":
                    if let format = attribute("KEYFORMAT", in: attributes), format != "identity" {
                        throw Failure.protected(format)
                    }
                    guard let uri = attribute("URI", in: attributes).flatMap({ URL(string: $0, relativeTo: base)?.absoluteURL }) else {
                        throw Failure.notAPlaylist
                    }
                    media.resources.append(Resource(kind: .key, uri: uri, byteRange: nil))
                    key = media.resources.count - 1
                    keyAttributes = attributes
                default:
                    throw Failure.protected(method)
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let segmentDuration = duration {
                guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                var range: Range<Int64>?
                if let byteRange {
                    let offset = byteRange.offset ?? lastRangeEnd[uri] ?? 0
                    range = offset..<(offset + byteRange.length)
                    lastRangeEnd[uri] = offset + byteRange.length
                }
                media.resources.append(Resource(kind: .segment, uri: uri, byteRange: range))
                media.segments.append(Segment(resource: media.resources.count - 1, duration: segmentDuration,
                                              map: map, key: key, keyAttributes: keyAttributes,
                                              discontinuity: discontinuity, programDateTime: programDateTime))
                duration = nil
                byteRange = nil
                discontinuity = false
                programDateTime = nil
            }
        }
        media.isEndless = !isVOD
        guard !media.segments.isEmpty else { throw Failure.notAPlaylist }
        return media
    }

    /// The local media playlist: every resource is served by the loopback
    /// server at `resourcePath(index)`; durations and keys' attributes are
    /// kept so the presentation is exactly as long as the original.
    static func localMedia(_ media: Media, resourcePath: (Int) -> String) -> String {
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(media.targetDuration)\n#EXT-X-MEDIA-SEQUENCE:\(media.mediaSequence)\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        var currentMap: Int?
        var currentKey: Int??
        for segment in media.segments {
            if segment.map != currentMap, let map = segment.map {
                out += "#EXT-X-MAP:URI=\"\(resourcePath(map))\"\n"
                currentMap = map
            }
            if currentKey != .some(segment.key) {
                if let key = segment.key, let attributes = segment.keyAttributes {
                    out += "#EXT-X-KEY:\(replacing("URI", in: attributes, with: resourcePath(key)))\n"
                } else if currentKey != nil {
                    out += "#EXT-X-KEY:METHOD=NONE\n"
                }
                currentKey = .some(segment.key)
            }
            if segment.discontinuity { out += "#EXT-X-DISCONTINUITY\n" }
            out += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n\(resourcePath(segment.resource))\n"
        }
        return out + "#EXT-X-ENDLIST\n"
    }

    static func localMaster(variant: Variant, videoPlaylist: String, audio: Rendition?, audioPlaylist: String?) -> String {
        var out = "#EXTM3U\n#EXT-X-VERSION:7\n"
        var attributes = "BANDWIDTH=\(max(1, variant.bandwidth))"
        if !variant.codecs.isEmpty { attributes += ",CODECS=\"\(variant.codecs)\"" }
        if variant.width > 0, variant.height > 0 { attributes += ",RESOLUTION=\(variant.width)x\(variant.height)" }
        if let audio, let audioPlaylist {
            let language = audio.language.map { ",LANGUAGE=\"\($0)\"" } ?? ""
            out += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(audio.name.isEmpty ? "Audio" : audio.name)\"\(language),DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audioPlaylist)\"\n"
            attributes += ",AUDIO=\"audio\""
        }
        return out + "#EXT-X-STREAM-INF:\(attributes)\n\(videoPlaylist)\n"
    }

    /// The best variant at or under `maxHeight` that the platform player can
    /// decode (H.264/HEVC video, or undeclared codecs), by height, then
    /// bandwidth; the smallest one when every variant is taller.
    static func bestVariant(_ variants: [Variant], maxHeight: Int) -> Variant? {
        let playable = variants.filter { variant in
            let codecs = variant.codecs.lowercased()
            return codecs.isEmpty || !(codecs.contains("vp09") || codecs.contains("vp9") || codecs.contains("av01"))
        }
        let candidates = playable.isEmpty ? variants : playable
        let order: (Variant, Variant) -> Bool = { a, b in
            a.height != b.height ? a.height < b.height : a.bandwidth < b.bandwidth
        }
        if let best = candidates.filter({ $0.height <= maxHeight || $0.height == 0 }).max(by: order) { return best }
        let smallest = candidates.map(\.height).min()
        return candidates.filter { $0.height == smallest }.max(by: order)
    }

    /// The audio rendition for `group`: the viewer's language, then the
    /// default, then the first.
    static func bestAudio(_ renditions: [Rendition], group: String?, language: String?) -> Rendition? {
        guard let group else { return nil }
        let inGroup = renditions.filter { $0.groupID == group && $0.uri != nil }
        if let language, let match = inGroup.first(where: { $0.language?.lowercased().hasPrefix(language.lowercased()) == true }) {
            return match
        }
        return inGroup.first(where: \.isDefault) ?? inGroup.first
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        var index = attributes.startIndex
        while index < attributes.endIndex {
            guard let equals = attributes[index...].firstIndex(of: "=") else { return nil }
            let key = attributes[index..<equals].trimmingCharacters(in: .whitespaces)
            var valueStart = attributes.index(after: equals)
            let value: Substring
            var next: String.Index
            if valueStart < attributes.endIndex, attributes[valueStart] == "\"" {
                valueStart = attributes.index(after: valueStart)
                let close = attributes[valueStart...].firstIndex(of: "\"") ?? attributes.endIndex
                value = attributes[valueStart..<close]
                next = close < attributes.endIndex ? attributes.index(after: close) : close
            } else {
                let comma = attributes[valueStart...].firstIndex(of: ",") ?? attributes.endIndex
                value = attributes[valueStart..<comma]
                next = comma
            }
            if key == name { return String(value) }
            if next < attributes.endIndex, attributes[next] == "," { next = attributes.index(after: next) }
            index = next
        }
        return nil
    }

    private static func replacing(_ name: String, in attributes: String, with value: String) -> String {
        guard let old = attribute(name, in: attributes) else { return attributes + ",\(name)=\"\(value)\"" }
        return attributes.replacingOccurrences(of: "\(name)=\"\(old)\"", with: "\(name)=\"\(value)\"")
    }

    private static func parseByteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard let length = parts.first.flatMap({ Int64($0) }) else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
    }
}
