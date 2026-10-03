import Foundation

// MARK: - Tolerant decoding

// Plugins are third-party JavaScript, so numbers may arrive as strings or floats and fields may be missing.
extension KeyedDecodingContainer {
    func looseString(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }
    func looseInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key), v.isFinite, abs(v) < 9e15 { return Int(v) }
        if let v = try? decodeIfPresent(String.self, forKey: key) { return Int(v) ?? Double(v).flatMap { $0.isFinite && abs($0) < 9e15 ? Int($0) : nil } }
        return nil
    }
    func looseBool(_ key: Key) -> Bool? {
        if let v = try? decodeIfPresent(Bool.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v != 0 }
        return nil
    }
}

// MARK: - Identity, thumbnails, authors

struct PlatformID: Hashable, Sendable, Codable {
    var platform: String = ""
    var pluginId: String = ""
    var value: String = ""
    var claimType: Int = 0

    enum CodingKeys: String, CodingKey { case platform, pluginId, value, claimType }

    init() {}
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) { value = single; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = c.looseString(.platform) ?? ""
        pluginId = c.looseString(.pluginId) ?? ""
        value = c.looseString(.value) ?? ""
        claimType = c.looseInt(.claimType) ?? 0
    }
}

struct Thumbnail: Hashable, Sendable, Codable {
    var url: String
    var quality: Int = 0
}

struct AuthorLink: Hashable, Sendable, Codable {
    var id: PlatformID = PlatformID()
    var name: String = ""
    var url: String = ""
    var thumbnail: String?
    var subscribers: Int?

    enum CodingKeys: String, CodingKey { case id, name, url, thumbnail, subscribers }

    init(id: PlatformID = PlatformID(), name: String, url: String, thumbnail: String? = nil, subscribers: Int? = nil) {
        self.id = id; self.name = name; self.url = url; self.thumbnail = thumbnail; self.subscribers = subscribers
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(PlatformID.self, forKey: .id)) ?? PlatformID()
        name = c.looseString(.name) ?? ""
        url = c.looseString(.url) ?? ""
        thumbnail = c.looseString(.thumbnail)
        subscribers = c.looseInt(.subscribers)
    }
}

// MARK: - Content items

enum ContentKind {
    case video, post, article, playlist, channel, nested, locked, web, other
}

/// One entry in a feed, search result list, channel listing or playlist.
struct ContentItem: Identifiable, Hashable, Sendable, Decodable {
    var contentType: Int = 0
    var platformID: PlatformID = PlatformID()
    var name: String = ""
    var url: String = ""
    var shareUrl: String?
    var author: AuthorLink?
    /// Seconds since the Unix epoch (UTC); nil when unknown.
    var datetime: Int?
    var thumbnails: [Thumbnail] = []
    var thumbnail: String?
    var duration: Int?
    var viewCount: Int?
    var isLive: Bool = false
    var isShort: Bool = false
    var videoCount: Int?
    var description: String?
    var images: [String] = []
    var subscribers: Int?
    var contentUrl: String?
    var unlockUrl: String?
    var lockDescription: String?
    var playbackTime: Int?
    var playbackDate: Int?

    var id: String { "\(platformID.pluginId)|\(url)" }
    static func == (l: ContentItem, r: ContentItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var kind: ContentKind {
        switch contentType {
        case 1: return .video
        case 2: return .post
        case 3: return .article
        case 4: return .playlist
        case 60: return .channel
        case 11: return .nested
        case 70: return .locked
        case 7: return .web
        default: return .other
        }
    }

    /// The URL to resolve when the user opens this item.
    var openURL: String { kind == .nested ? (contentUrl ?? url) : url }

    var thumbnailURL: URL? {
        if let best = thumbnails.max(by: { $0.quality < $1.quality }), let u = URL(string: best.url) { return u }
        if let t = thumbnail, let u = URL(string: t) { return u }
        return nil
    }

    var date: Date? { datetime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }

    enum CodingKeys: String, CodingKey {
        case contentType, id, name, url, shareUrl, author, datetime, thumbnails, thumbnail, duration, viewCount
        case isLive, isShort, videoCount, description, images, subscribers, contentUrl, contentName
        case contentThumbnails, unlockUrl, lockDescription, playbackTime, playbackDate, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentType = c.looseInt(.contentType) ?? 0
        platformID = (try? c.decodeIfPresent(PlatformID.self, forKey: .id)) ?? PlatformID()
        name = c.looseString(.name) ?? c.looseString(.contentName) ?? ""
        url = c.looseString(.url) ?? ""
        shareUrl = c.looseString(.shareUrl)
        author = try? c.decodeIfPresent(AuthorLink.self, forKey: .author)
        datetime = c.looseInt(.datetime)
        thumbnails = Self.decodeThumbnails(c, .thumbnails)
        if thumbnails.isEmpty { thumbnails = Self.decodeThumbnails(c, .contentThumbnails) }
        thumbnail = c.looseString(.thumbnail)
        duration = c.looseInt(.duration)
        viewCount = c.looseInt(.viewCount)
        isLive = c.looseBool(.isLive) ?? false
        isShort = c.looseBool(.isShort) ?? false
        videoCount = c.looseInt(.videoCount)
        description = c.looseString(.description) ?? c.looseString(.summary)
        images = (try? c.decodeIfPresent([String].self, forKey: .images)) ?? []
        subscribers = c.looseInt(.subscribers)
        contentUrl = c.looseString(.contentUrl)
        unlockUrl = c.looseString(.unlockUrl)
        lockDescription = c.looseString(.lockDescription)
        playbackTime = c.looseInt(.playbackTime)
        playbackDate = c.looseInt(.playbackDate)
    }

    private struct ThumbnailSet: Decodable { var sources: [Thumbnail]? }

    private static func decodeThumbnails(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Thumbnail] {
        if let set = try? c.decodeIfPresent(ThumbnailSet.self, forKey: key), let s = set.sources { return s }
        if let list = try? c.decodeIfPresent([Thumbnail].self, forKey: key) { return list }
        if let strings = try? c.decodeIfPresent([String].self, forKey: key) { return strings.map { Thumbnail(url: $0) } }
        return []
    }
}

// MARK: - Channels

struct ChannelInfo: Sendable, Decodable, Hashable {
    var idString: String = ""
    var name: String = ""
    var thumbnail: String?
    var banner: String?
    var subscribers: Int?
    var description: String?
    var url: String = ""
    var urlAlternatives: [String] = []
    var links: [String: String] = [:]

    enum CodingKeys: String, CodingKey { case id, name, thumbnail, banner, subscribers, description, url, urlAlternatives, links }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pid = try? c.decodeIfPresent(PlatformID.self, forKey: .id) { idString = pid.value }
        name = c.looseString(.name) ?? ""
        thumbnail = c.looseString(.thumbnail)
        banner = c.looseString(.banner)
        subscribers = c.looseInt(.subscribers)
        description = c.looseString(.description)
        url = c.looseString(.url) ?? ""
        urlAlternatives = (try? c.decodeIfPresent([String].self, forKey: .urlAlternatives)) ?? []
        links = (try? c.decodeIfPresent([String: String].self, forKey: .links)) ?? [:]
    }

    init(name: String, url: String, thumbnail: String?) { self.name = name; self.url = url; self.thumbnail = thumbnail }
}

// MARK: - Ratings, comments

struct Rating: Sendable, Decodable, Hashable {
    var type: Int = 0
    var likes: Int?
    var dislikes: Int?
    var value: Double?

    enum CodingKeys: String, CodingKey { case type, likes, dislikes, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.looseInt(.type) ?? 0
        likes = c.looseInt(.likes)
        dislikes = c.looseInt(.dislikes)
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? nil
    }
}

struct PluginComment: Identifiable, Sendable, Decodable, Hashable {
    var handle: Int = 0
    var author: AuthorLink = AuthorLink(name: "", url: "")
    var message: String = ""
    var rating: Rating?
    var date: Int = 0
    var replyCount: Int = 0
    var contextUrl: String = ""

    var id: Int { handle }
    enum CodingKeys: String, CodingKey { case author, message, rating, date, replyCount, contextUrl, __handle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = c.looseInt(.__handle) ?? 0
        author = (try? c.decodeIfPresent(AuthorLink.self, forKey: .author)) ?? AuthorLink(name: "", url: "")
        message = c.looseString(.message) ?? ""
        rating = try? c.decodeIfPresent(Rating.self, forKey: .rating)
        date = c.looseInt(.date) ?? 0
        replyCount = c.looseInt(.replyCount) ?? 0
        contextUrl = c.looseString(.contextUrl) ?? ""
    }
}

// MARK: - Search / channel capabilities

struct FilterCapability: Sendable, Decodable, Hashable, Identifiable {
    var key: String
    var name: String
    var value: String
    var id: String { key }

    enum CodingKeys: String, CodingKey { case id, name, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.looseString(.name) ?? ""
        value = c.looseString(.value) ?? ""
        key = c.looseString(.id) ?? name
    }
}

struct FilterGroup: Sendable, Decodable, Hashable, Identifiable {
    var key: String
    var name: String
    var isMultiSelect: Bool
    var filters: [FilterCapability]
    var id: String { key }

    enum CodingKeys: String, CodingKey { case id, name, isMultiSelect, filters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.looseString(.name) ?? ""
        key = c.looseString(.id) ?? name
        isMultiSelect = c.looseBool(.isMultiSelect) ?? false
        filters = ((try? c.decodeIfPresent([Lossy<FilterCapability>].self, forKey: .filters)) ?? []).compactMap { $0.value }
    }
}

struct ResultCapabilities: Sendable, Decodable, Hashable {
    var types: [String] = ["MIXED"]
    var sorts: [String] = []
    var filters: [FilterGroup] = []

    enum CodingKeys: String, CodingKey { case types, sorts, filters }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        types = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? ["MIXED"]
        sorts = (try? c.decodeIfPresent([String].self, forKey: .sorts)) ?? []
        filters = ((try? c.decodeIfPresent([Lossy<FilterGroup>].self, forKey: .filters)) ?? []).compactMap { $0.value }
    }
}
