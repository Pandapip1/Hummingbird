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

struct PlatformID: Hashable, Sendable, Codable, PluginOutput {
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

    /// Binds the id to the plugin that produced it: a plugin cannot claim
    /// another plugin's identity (icon, name, routing).
    mutating func contain(_ context: PluginOutputContext) {
        pluginId = context.pluginID
        platform = context.line(platform, limit: 100)
        value = context.reference(value)
    }
}

struct Thumbnail: Hashable, Sendable, Codable, PluginOutput {
    var url: String
    var quality: Int = 0

    /// An unusable URL becomes empty; `ContentItem.contain` drops those.
    mutating func contain(_ context: PluginOutputContext) {
        url = context.webURL(url) ?? ""
    }
}

struct AuthorLink: Hashable, Sendable, Codable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        id.contain(context)
        name = context.line(name)
        url = context.reference(url)
        thumbnail = context.webURL(thumbnail)
    }
}

// MARK: - Content items

enum ContentKind {
    case video, post, article, playlist, channel, nested, locked, web, other
}

/// One entry in a feed, search result list, channel listing or playlist.
struct ContentItem: Identifiable, Hashable, Sendable, Decodable, PluginOutput {
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
    /// Where the user can unlock locked content, outside the app. Only set
    /// by `contain`, so an uncontained item never opens anything.
    var unlockURL: NavigableURL?
    /// The plugin's raw value, until containment checks it.
    private var unlockURLCandidate: String?
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
        unlockURLCandidate = c.looseString(.unlockUrl)
        lockDescription = c.looseString(.lockDescription)
        playbackTime = c.looseInt(.playbackTime)
        playbackDate = c.looseInt(.playbackDate)
    }

    mutating func contain(_ context: PluginOutputContext) {
        platformID.contain(context)
        name = context.line(name)
        url = context.reference(url)
        shareUrl = context.navigableURL(shareUrl)?.url.absoluteString
        author?.contain(context)
        thumbnails = context.contained(thumbnails, limit: 32).filter { !$0.url.isEmpty }
        thumbnail = context.webURL(thumbnail)
        description = context.optionalText(description)
        images = context.list(images, limit: 64).compactMap { context.webURL($0) }
        contentUrl = contentUrl.map { context.reference($0) }
        unlockURL = context.navigableURL(unlockURLCandidate)
        unlockURLCandidate = nil
        lockDescription = context.optionalText(lockDescription, limit: 2_000)
        if let d = duration, d < 0 { duration = nil }
        if let v = viewCount, v < 0 { viewCount = nil }
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

struct ChannelInfo: Sendable, Decodable, Hashable, PluginOutput {
    var idString: String = ""
    var name: String = ""
    var thumbnail: String?
    var banner: String?
    var subscribers: Int?
    var description: String?
    var url: String = ""
    var urlAlternatives: [String] = []
    /// Named external links. Only set by `contain`.
    var links: [String: NavigableURL] = [:]
    private var linkCandidates: [String: String] = [:]

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
        linkCandidates = (try? c.decodeIfPresent([String: String].self, forKey: .links)) ?? [:]
    }

    mutating func contain(_ context: PluginOutputContext) {
        idString = context.reference(idString)
        name = context.line(name)
        thumbnail = context.webURL(thumbnail)
        banner = context.webURL(banner)
        description = context.optionalText(description)
        url = context.reference(url)
        urlAlternatives = context.list(urlAlternatives, limit: 32).map { context.reference($0) }
        var contained: [String: NavigableURL] = [:]
        for (name, link) in linkCandidates.prefix(32) {
            if let url = context.navigableURL(link) { contained[context.line(name, limit: 100)] = url }
        }
        links = contained
        linkCandidates = [:]
        if let s = subscribers, s < 0 { subscribers = nil }
    }

    init(name: String, url: String, thumbnail: String?) { self.name = name; self.url = url; self.thumbnail = thumbnail }
}

// MARK: - Ratings, comments

struct Rating: Sendable, Decodable, Hashable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        if let v = value, !v.isFinite { value = nil }
    }
}

struct PluginComment: Identifiable, Sendable, Decodable, Hashable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        author.contain(context)
        message = context.text(message, limit: 20_000)
        rating?.contain(context)
        replyCount = max(0, replyCount)
        contextUrl = context.reference(contextUrl)
    }
}

// MARK: - Search / channel capabilities

struct FilterCapability: Sendable, Decodable, Hashable, Identifiable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        key = context.line(key, limit: 200)
        name = context.line(name, limit: 200)
        value = context.line(value, limit: 1_000)
    }
}

struct FilterGroup: Sendable, Decodable, Hashable, Identifiable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        key = context.line(key, limit: 200)
        name = context.line(name, limit: 200)
        filters = context.contained(filters, limit: 100)
    }
}

struct ResultCapabilities: Sendable, Decodable, Hashable, PluginOutput {
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

    mutating func contain(_ context: PluginOutputContext) {
        types = context.list(types, limit: 20).map { context.line($0, limit: 100) }
        sorts = context.list(sorts, limit: 50).map { context.line($0, limit: 200) }
        filters = context.contained(filters, limit: 50)
    }
}
