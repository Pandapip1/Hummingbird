import Foundation
import Observation

private func capture<T>(_ op: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await op()) } catch { return .failure(error) }
}

/// Routes URLs and feed requests to the right plugin runtimes.
@MainActor
final class PlatformService {
    let plugins: PluginManager
    private var capabilityCache: [String: ResultCapabilities] = [:]
    private var routeCache: [String: String] = [:]

    init(plugins: PluginManager) { self.plugins = plugins }

    // MARK: errors

    /// Records login / captcha demands so the UI can offer the right flow. Returns a message for display.
    func surface(_ error: Error, pluginID: String) -> String {
        if let e = error as? PluginError {
            switch e {
            case .captchaRequired(let url, let body):
                plugins.pendingCaptcha = PluginManager.CaptchaRequest(pluginID: pluginID, url: url, body: body)
            case .loginRequired:
                plugins.pendingLogin = pluginID
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Runs `op`; if the plugin asks to be reloaded, restarts it (exposing `__reloadData`) and tries once more.
    func withReload<T>(_ rt: PluginRuntime, _ op: () async throws -> T) async throws -> T {
        do { return try await op() }
        catch let PluginError.reloadRequired(_, data) {
            await rt.reload(reloadData: data)
            return try await op()
        }
    }

    // MARK: URL routing

    private func route(url: String, check: String, requires: [String] = []) async -> PluginRuntime? {
        let key = check + "|" + url
        if let id = routeCache[key], let rt = plugins.runtime(for: id), plugins.plugin(id)?.enabled == true { return rt }
        for p in plugins.enabledPlugins {
            guard let rt = plugins.runtime(for: p.id) else { continue }
            if (try? await rt.enable()) == nil { continue }
            if !requires.allSatisfy({ rt.has($0) }) { continue }
            if let yes = try? await rt.call(check, [url], as: Bool.self), yes {
                routeCache[key] = p.id
                return rt
            }
        }
        return nil
    }

    func details(url: String) async throws -> (PluginRuntime, ContentDetails) {
        guard let rt = await route(url: url, check: "isContentDetailsUrl") else { throw PluginError.notInstalled }
        do {
            let data = try await withReload(rt) { try await rt.callRaw("getContentDetails", [url], kind: "details") }
            return (rt, try PluginRuntime.decode(ContentDetails.self, from: data))
        } catch { _ = surface(error, pluginID: rt.id); throw error }
    }

    func channel(url: String) async throws -> (PluginRuntime, ChannelInfo) {
        guard let rt = await route(url: url, check: "isChannelUrl") else { throw PluginError.notInstalled }
        do {
            let info = try await withReload(rt) { try await rt.call("getChannel", [url], as: ChannelInfo.self) }
            return (rt, info)
        } catch { _ = surface(error, pluginID: rt.id); throw error }
    }

    func playlist(url: String) async throws -> (PluginRuntime, PlaylistDetailsPayload, PluginPager<ContentItem>) {
        guard let rt = await route(url: url, check: "isPlaylistUrl", requires: ["getPlaylist", "isPlaylistUrl"]) else { throw PluginError.notInstalled }
        do {
            let data = try await withReload(rt) { try await rt.callRaw("getPlaylist", [url], kind: "playlist") }
            let payload = try PluginRuntime.decode(PlaylistDetailsPayload.self, from: data)
            return (rt, payload, PluginPager(runtime: rt, payload: payload.contents))
        } catch { _ = surface(error, pluginID: rt.id); throw error }
    }

    /// What kind of thing a pasted URL is, if any plugin recognises it.
    func classify(url: String) async -> Route? {
        if await route(url: url, check: "isContentDetailsUrl") != nil { return .content(url) }
        if await route(url: url, check: "isChannelUrl") != nil { return .channel(url) }
        if await route(url: url, check: "isPlaylistUrl", requires: ["getPlaylist", "isPlaylistUrl"]) != nil { return .playlist(url) }
        return nil
    }

    // MARK: capabilities

    private func capabilities(_ rt: PluginRuntime, method: String) async -> ResultCapabilities {
        let key = rt.id + "|" + method
        if let c = capabilityCache[key] { return c }
        var caps = ResultCapabilities()
        if rt.has(method), let c = try? await rt.call(method, [], as: ResultCapabilities.self) { caps = c }
        capabilityCache[key] = caps
        return caps
    }
    func channelCapabilities(_ rt: PluginRuntime) async -> ResultCapabilities { await capabilities(rt, method: "getChannelCapabilities") }
    func searchCapabilities(_ rt: PluginRuntime) async -> ResultCapabilities { await capabilities(rt, method: "getSearchCapabilities") }

    // MARK: feeds

    func homeSources() -> [FeedSource] {
        plugins.enabledPlugins.filter { $0.config.enableInHome }.compactMap { p in
            guard let rt = plugins.runtime(for: p.id) else { return nil }
            return FeedSource(runtime: rt, label: p.config.name) { [self] in
                try await withReload(rt) { try await rt.pager("getHome", [], as: ContentItem.self) }
            }
        }
    }

    func searchSources(query: String, type: String?, order: String?) -> [FeedSource] {
        plugins.enabledPlugins.filter { $0.config.enableInSearch }.compactMap { p in
            guard let rt = plugins.runtime(for: p.id) else { return nil }
            return FeedSource(runtime: rt, label: p.config.name) { [self] in
                try await withReload(rt) {
                    try await rt.pager("search", [query, type ?? NSNull(), order ?? NSNull(), NSNull()], as: ContentItem.self)
                }
            }
        }
    }

    func channelSource(runtime rt: PluginRuntime, url: String, type: String?, order: String?, filters: [String: [String]]? = nil) -> FeedSource {
        FeedSource(runtime: rt, label: rt.config.name) { [self] in
            try await withReload(rt) {
                try await rt.pager("getChannelContents", [url, type ?? NSNull(), order ?? NSNull(), filters ?? NSNull()], as: ContentItem.self)
            }
        }
    }

    func recommendations(runtime rt: PluginRuntime, details: VideoDetails) async -> PluginPager<ContentItem>? {
        if details.hasRecommendations, let p = try? await rt.handlePager(details.handle, "getContentRecommendations", [], as: ContentItem.self) { return p }
        if rt.has("getContentRecommendations") {
            return try? await rt.pager("getContentRecommendations", [details.item.url, NSNull()], as: ContentItem.self)
        }
        return nil
    }

    func comments(runtime rt: PluginRuntime, details: VideoDetails) async throws -> PluginPager<PluginComment>? {
        if details.hasComments { return try await rt.handlePager(details.handle, "getComments", [], as: PluginComment.self) }
        if rt.has("getComments") { return try await rt.pager("getComments", [details.item.url], as: PluginComment.self) }
        return nil
    }

    func searchChannels(query: String) async -> [(PluginRuntime, ContentItem)] {
        var out: [(PluginRuntime, ContentItem)] = []
        for p in plugins.enabledPlugins where p.config.enableInSearch {
            guard let rt = plugins.runtime(for: p.id), (try? await rt.enable()) != nil, rt.has("searchChannels") else { continue }
            if let pager = try? await rt.pager("searchChannels", [query], as: ContentItem.self) {
                out.append(contentsOf: pager.initial.map { (rt, $0) })
            }
        }
        return out
    }
}

// MARK: - Navigation

enum Route: Hashable {
    case content(String)        // content details URL
    case item(ContentItem)      // content we already have partial data for
    case channel(String)
    case playlist(String)
    case plugin(String)
}

// MARK: - Merged feeds

struct FeedSource {
    let runtime: PluginRuntime
    let label: String
    let open: () async throws -> PluginPager<ContentItem>
}

/// Loads pages from several plugins and interleaves them so no single plugin dominates the list.
@MainActor
@Observable
final class FeedModel {
    private(set) var items: [ContentItem] = []
    private(set) var isLoading = false
    private(set) var messages: [String] = []
    private(set) var hasMore = false
    private(set) var loadedOnce = false

    @ObservationIgnored private var sources: [FeedSource] = []
    @ObservationIgnored private var pagers: [(FeedSource, PluginPager<ContentItem>)] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private let report: (Error, PluginRuntime) -> String
    @ObservationIgnored private let didUpdate: (([ContentItem]) -> Void)?

    init(initialItems: [ContentItem] = [],
         report: @escaping (Error, PluginRuntime) -> String,
         didUpdate: (([ContentItem]) -> Void)? = nil) {
        self.items = initialItems
        self.seen = Set(initialItems.map(\.id))
        self.report = report
        self.didUpdate = didUpdate
    }

    func reload(sources: [FeedSource]) async {
        self.sources = sources
        isLoading = true
        messages = []
        pagers = []
        seen = []
        var results: [(Int, Result<PluginPager<ContentItem>, Error>)] = []
        await withTaskGroup(of: (Int, Result<PluginPager<ContentItem>, Error>).self) { group in
            for (i, s) in sources.enumerated() { group.addTask { (i, await capture { try await s.open() }) } }
            for await r in group { results.append(r) }
        }
        results.sort { $0.0 < $1.0 }
        var columns: [[ContentItem]] = []
        var refreshed = false
        for (i, r) in results {
            switch r {
            case .success(let p):
                refreshed = true
                pagers.append((sources[i], p))
                columns.append(p.initial)
            case .failure(let e):
                messages.append("\(sources[i].label): \(report(e, sources[i].runtime))")
            }
        }
        if refreshed {
            items = []
            seen = []
            append(interleave(columns))
            didUpdate?(items)
        }
        hasMore = pagers.contains { $0.1.hasMore }
        isLoading = false
        loadedOnce = true
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        var results: [(Int, Result<[ContentItem], Error>)] = []
        let active = pagers
        await withTaskGroup(of: (Int, Result<[ContentItem], Error>).self) { group in
            for (i, entry) in active.enumerated() where entry.1.hasMore {
                group.addTask { (i, await capture { try await entry.1.next() }) }
            }
            for await r in group { results.append(r) }
        }
        results.sort { $0.0 < $1.0 }
        var columns: [[ContentItem]] = []
        for (i, r) in results {
            switch r {
            case .success(let page): columns.append(page)
            case .failure(let e): messages.append("\(active[i].0.label): \(report(e, active[i].0.runtime))")
            }
        }
        append(interleave(columns))
        didUpdate?(items)
        hasMore = pagers.contains { $0.1.hasMore }
        isLoading = false
    }

    private func append(_ new: [ContentItem]) {
        for item in new where !item.url.isEmpty && seen.insert(item.id).inserted { items.append(item) }
    }

    private func interleave(_ columns: [[ContentItem]]) -> [ContentItem] {
        var out: [ContentItem] = []
        var i = 0
        while columns.contains(where: { i < $0.count }) {
            for col in columns where i < col.count { out.append(col[i]) }
            i += 1
        }
        return out
    }
}
