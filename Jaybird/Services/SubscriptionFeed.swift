import Foundation
import Observation

/// Builds the subscriptions feed: fetches the first page of each subscribed channel (newest first), respects each
/// plugin's rate limit by falling back to cached results, and merges everything chronologically.
@MainActor
@Observable
final class SubscriptionFeed {
    private(set) var items: [ContentItem] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var failures: [String: String] = [:]
    var visibleCount = 30

    var visibleItems: [ContentItem] { Array(items.prefix(visibleCount)) }
    var hasMoreToShow: Bool { visibleCount < items.count }
    func showMore() { visibleCount += 30 }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let plugins: PluginManager
    @ObservationIgnored private let platform: PlatformService
    private static let maxConcurrent = 6

    init(library: LibraryStore, plugins: PluginManager, platform: PlatformService) {
        self.library = library; self.plugins = plugins; self.platform = platform
        // Show cached items immediately on launch.
        items = Self.merge(library.feedCache.values.flatMap { $0 }.map { ContentItem(saved: $0) })
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        failures = [:]
        defer { isRefreshing = false }

        let userLimit = UserDefaults.standard.integer(forKey: "subscriptionFetchLimit")   // 0 = unlimited
        var jobs: [Subscription] = []
        var cached: [ContentItem] = []

        // Per plugin: oldest-fetched channels first, up to the rate limit; the rest are served from cache.
        for (pluginID, subs) in Dictionary(grouping: library.subscriptions, by: \.pluginId) {
            guard let plugin = plugins.plugin(pluginID), plugin.enabled else { continue }
            let limits = [plugin.config.subscriptionRateLimit, userLimit > 0 ? userLimit : nil].compactMap { $0 }.filter { $0 > 0 }
            let budget = limits.min() ?? Int.max
            let ordered = subs.sorted { ($0.lastFetched ?? .distantPast) < ($1.lastFetched ?? .distantPast) }
            jobs.append(contentsOf: ordered.prefix(budget))
            for s in ordered.dropFirst(budget) { cached.append(contentsOf: (library.feedCache[s.channelURL] ?? []).map { ContentItem(saved: $0) }) }
        }

        var fetched: [ContentItem] = []
        await withTaskGroup(of: (Subscription, Result<[ContentItem], Error>).self) { group in
            var iterator = jobs.makeIterator()
            var running = 0
            func addNext() {
                guard let sub = iterator.next() else { return }
                running += 1
                group.addTask { @MainActor [self] in
                    do { return (sub, .success(try await fetchChannel(sub))) } catch { return (sub, .failure(error)) }
                }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            for await (sub, result) in group {
                running -= 1
                switch result {
                case .success(let list):
                    fetched.append(contentsOf: list)
                    let saved = list.prefix(30).map { SavedVideo($0) }
                    library.updateSubscription(sub.channelURL, fetched: Date(), newest: list.compactMap(\.datetime).max(), cache: Array(saved))
                case .failure(let e):
                    failures[sub.channelURL] = platform.surface(e, pluginID: sub.pluginId)
                    // Fall back to whatever we last saw for this channel.
                    cached.append(contentsOf: (library.feedCache[sub.channelURL] ?? []).map { ContentItem(saved: $0) })
                }
                addNext()
            }
        }
        library.persistSubscriptionState()
        items = Self.merge(fetched + cached)
        visibleCount = 30
        lastRefresh = Date()
    }

    /// First page(s) of one channel, newest first. Plugins that cannot mix content types get one call per type.
    private func fetchChannel(_ sub: Subscription) async throws -> [ContentItem] {
        guard let rt = plugins.runtime(for: sub.pluginId) else { throw PluginError.notInstalled }
        try await rt.enable()
        let caps = await platform.channelCapabilities(rt)
        let wanted = ["VIDEOS", "STREAMS", "POSTS", "LIVE"]
        let types: [String?]
        if caps.types.isEmpty || caps.types.contains("MIXED") { types = [nil] }
        else if caps.types.contains("SUBSCRIPTIONS") { types = ["SUBSCRIPTIONS"] }
        else { types = caps.types.filter { wanted.contains($0) } }
        if types.isEmpty { return [] }

        var all: [ContentItem] = []
        for t in types {
            let pager = try await platform.withReload(rt) {
                try await rt.pager("getChannelContents", [sub.channelURL, t ?? NSNull(), "CHRONOLOGICAL", NSNull()], as: ContentItem.self)
            }
            all.append(contentsOf: pager.initial)
        }
        return all.filter { [.video, .nested, .post, .article].contains($0.kind) }
    }

    /// Newest first; items with unknown dates sort last. Near-duplicates (same title around the same time, e.g. the
    /// same upload mirrored by two plugins) are collapsed to the first one seen.
    static func merge(_ items: [ContentItem]) -> [ContentItem] {
        var byName: [String: [ContentItem]] = [:]
        var order: [ContentItem] = []
        for item in items {
            let key = item.name.lowercased()
            if let dates = byName[key], let d = item.datetime {
                let ageDays = abs(Date().timeIntervalSince1970 - Double(d)) / 86_400
                let window = max(2.0, ageDays / 1.5)
                let isDup = dates.contains { other in
                    guard let od = other.datetime else { return false }
                    return abs(Double(od - d)) / 86_400 < window && other.id != item.id
                }
                if isDup { continue }
            }
            byName[key, default: []].append(item)
            order.append(item)
        }
        var seen = Set<String>()
        return order.filter { seen.insert($0.id).inserted }.sorted { ($0.datetime ?? Int.min) > ($1.datetime ?? Int.min) }
    }
}
