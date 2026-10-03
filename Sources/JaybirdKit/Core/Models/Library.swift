import Foundation

/// A video remembered by the library (history, watch later, playlists, cached subscription items).
struct SavedVideo: Codable, Hashable, Identifiable, Sendable {
    var pluginId: String
    var url: String
    var name: String
    var thumbnailURL: String?
    var authorName: String?
    var authorURL: String?
    var authorThumbnail: String?
    var duration: Int?
    var datetime: Int?
    var viewCount: Int?
    var isLive: Bool = false
    var contentType: Int = 1

    var id: String { pluginId + "|" + url }

    init(_ item: ContentItem) {
        pluginId = item.platformID.pluginId
        url = item.url
        name = item.name
        thumbnailURL = item.thumbnailURL?.absoluteString
        authorName = item.author?.name
        authorURL = item.author?.url
        authorThumbnail = item.author?.thumbnail
        duration = item.duration
        datetime = item.datetime
        viewCount = item.viewCount
        isLive = item.isLive
        contentType = item.contentType == 0 ? 1 : item.contentType
    }
}

extension ContentItem {
    init(saved v: SavedVideo) {
        contentType = v.contentType
        platformID = PlatformID()
        platformID.pluginId = v.pluginId
        name = v.name
        url = v.url
        if let t = v.thumbnailURL { thumbnails = [Thumbnail(url: t, quality: 1)] }
        if let n = v.authorName { author = AuthorLink(name: n, url: v.authorURL ?? "", thumbnail: v.authorThumbnail) }
        duration = v.duration
        datetime = v.datetime
        viewCount = v.viewCount
        isLive = v.isLive
    }
}

struct Subscription: Codable, Hashable, Identifiable, Sendable {
    var channelURL: String
    var pluginId: String
    var name: String
    var thumbnail: String?
    var subscribers: Int?
    var created: Date = Date()
    var lastFetched: Date?
    /// Epoch seconds of the newest item seen; used to decide which channels to refresh first.
    var lastItemDate: Int?
    var id: String { channelURL }
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var videos: [SavedVideo] = []
    var created: Date = Date()
    var updated: Date = Date()
}

struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var video: SavedVideo
    /// Playback position in seconds.
    var position: Double
    var date: Date
    var id: String { video.id }
}

/// Everything the user owns, in one export file. This is Jaybird's own format.
struct LibraryBackup: Codable {
    var version: Int = 1
    var subscriptions: [Subscription]
    var playlists: [Playlist]
    var watchLater: [SavedVideo]
    var history: [HistoryEntry]
    var pluginSources: [String: String]   // plugin id -> config URL, so plugins can be reinstalled
}
