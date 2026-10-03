import Foundation

// MARK: - Media sources

struct RequestModifierRef: Sendable, Decodable, Hashable {
    var handle: Int
    var allowByteSkip: Bool = true
}

/// A playable stream description. `pluginType` is the plugin's source class name, e.g. "VideoUrlSource", "HLSSource".
struct MediaSource: Sendable, Decodable, Hashable, Identifiable {
    var pluginType: String = ""
    var name: String = ""
    var url: String = ""
    var width: Int = 0
    var height: Int = 0
    var container: String = ""
    var codec: String = ""
    var bitrate: Int = 0
    var duration: Int = 0
    var language: String = "Unknown"
    var priority: Bool = false
    var original: Bool = false
    var requestModifier: RequestModifierRef?

    var id: String { "\(pluginType)|\(url)" }
    var isHLS: Bool { pluginType.hasPrefix("HLS") }
    var isDash: Bool { pluginType.hasPrefix("Dash") }
    var isWidevine: Bool { pluginType.contains("Widevine") }

    enum CodingKeys: String, CodingKey {
        case plugin_type, name, url, width, height, container, codec, bitrate, duration, language, priority, original, requestModifier
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginType = c.looseString(.plugin_type) ?? ""
        name = c.looseString(.name) ?? ""
        url = c.looseString(.url) ?? ""
        width = c.looseInt(.width) ?? 0
        height = c.looseInt(.height) ?? 0
        container = c.looseString(.container) ?? ""
        codec = c.looseString(.codec) ?? ""
        bitrate = c.looseInt(.bitrate) ?? 0
        duration = c.looseInt(.duration) ?? 0
        language = c.looseString(.language) ?? "Unknown"
        priority = c.looseBool(.priority) ?? false
        original = c.looseBool(.original) ?? false
        requestModifier = try? c.decodeIfPresent(RequestModifierRef.self, forKey: .requestModifier)
    }
}

struct SubtitleSource: Sendable, Decodable, Hashable, Identifiable {
    var name: String = ""
    var language: String?
    var url: String?
    var format: String?
    var getSubtitlesHandle: Int?
    var id: String { "\(name)|\(url ?? "")|\(getSubtitlesHandle ?? 0)" }

    enum CodingKeys: String, CodingKey { case name, language, url, format, getSubtitlesHandle }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.looseString(.name) ?? ""
        language = c.looseString(.language)
        url = c.looseString(.url)
        format = c.looseString(.format)
        getSubtitlesHandle = c.looseInt(.getSubtitlesHandle)
    }
}

// MARK: - Details

struct VideoDetails: Sendable, Decodable {
    var item: ContentItem
    var description: String = ""
    var isUnmuxed: Bool = false
    var videoSources: [MediaSource] = []
    var audioSources: [MediaSource] = []
    var hls: MediaSource?
    var dash: MediaSource?
    var live: MediaSource?
    var rating: Rating?
    var subtitles: [SubtitleSource] = []
    /// Handle of the details object inside the plugin runtime (for comments, trackers, recommendations).
    var handle: Int = 0
    var hasComments = false
    var hasTracker = false
    var hasRecommendations = false

    private struct Descriptor: Decodable {
        var isUnMuxed: Bool?
        var videoSources: [Lossy<MediaSource>]?
        var audioSources: [Lossy<MediaSource>]?
    }
    enum CodingKeys: String, CodingKey {
        case description, video, hls, dash, live, rating, subtitles, __handle
        case has_getComments, has_getPlaybackTracker, has_getContentRecommendations
    }

    init(from decoder: Decoder) throws {
        item = try ContentItem(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = c.looseString(.description) ?? ""
        if let d = try? c.decodeIfPresent(Descriptor.self, forKey: .video) {
            isUnmuxed = d.isUnMuxed ?? false
            videoSources = (d.videoSources ?? []).compactMap { $0.value }
            audioSources = (d.audioSources ?? []).compactMap { $0.value }
        }
        hls = try? c.decodeIfPresent(MediaSource.self, forKey: .hls)
        dash = try? c.decodeIfPresent(MediaSource.self, forKey: .dash)
        live = try? c.decodeIfPresent(MediaSource.self, forKey: .live)
        rating = try? c.decodeIfPresent(Rating.self, forKey: .rating)
        subtitles = ((try? c.decodeIfPresent([Lossy<SubtitleSource>].self, forKey: .subtitles)) ?? []).compactMap { $0.value }
        handle = c.looseInt(.__handle) ?? 0
        hasComments = c.looseBool(.has_getComments) ?? false
        hasTracker = c.looseBool(.has_getPlaybackTracker) ?? false
        hasRecommendations = c.looseBool(.has_getContentRecommendations) ?? false
    }
}

struct PostDetails: Sendable, Decodable {
    var item: ContentItem
    var content: String = ""
    /// 0 raw text, 1 HTML, 2 markup
    var textType: Int = 0
    var rating: Rating?

    enum CodingKeys: String, CodingKey { case content, textType, rating }
    init(from decoder: Decoder) throws {
        item = try ContentItem(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = c.looseString(.content) ?? item.description ?? ""
        textType = c.looseInt(.textType) ?? 0
        rating = try? c.decodeIfPresent(Rating.self, forKey: .rating)
    }
}

/// The result of resolving a content URL.
enum ContentDetails: Sendable, Decodable {
    case video(VideoDetails)
    case post(PostDetails)
    case other(ContentItem)

    init(from decoder: Decoder) throws {
        let item = try ContentItem(from: decoder)
        switch item.contentType {
        case 1: self = .video(try VideoDetails(from: decoder))
        case 2, 3: self = .post(try PostDetails(from: decoder))
        default: self = .other(item)
        }
    }

    var item: ContentItem {
        switch self {
        case .video(let v): return v.item
        case .post(let p): return p.item
        case .other(let i): return i
        }
    }
}

struct PlaylistDetailsPayload: Sendable, Decodable {
    var header: ContentItem
    var contents: PagerPayload<ContentItem>

    enum CodingKeys: String, CodingKey { case contents }
    init(from decoder: Decoder) throws {
        header = try ContentItem(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contents = (try? c.decode(PagerPayload<ContentItem>.self, forKey: .contents))
            ?? PagerPayload(pager: 0, results: [], hasMore: false, nextRequest: nil)
    }
}
