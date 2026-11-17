import Foundation
import SwiftOpenUI

// MARK: - Channel

@MainActor
struct ChannelView: View {
    let url: String
    @Environment(AppModel.self) private var app
    @State private var loadState: LoadState = .loading
    @State private var feed: FeedModel?
    @State private var caps = ResultCapabilities()
    /// What the feed shows. Changes only once the plugin has delivered it.
    @State private var selection = ChannelFeedSelection()
    /// A type or sort the feed is loading; the controls are pending meanwhile.
    @State private var pending: ChannelFeedSelection?
    @State private var expanded = false

    enum LoadState { case loading, failed(String), loaded(PluginRuntime, ChannelInfo) }

    var body: some View {
        Group {
            switch loadState {
            case .loading: ProgressView()
            case .failed(let m): LoadingErrorView(message: m) { Task { await load() } }
            case .loaded(let rt, let info): content(rt, info)
            }
        }
        .detailNavigationStyle()
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private func content(_ rt: PluginRuntime, _ info: ChannelInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(rt, info)
                let pickerTypes = ChannelFeedPlan.pickerTypes(advertised: caps.types)
                if pickerTypes.count > 2 || !caps.sorts.isEmpty {
                    HStack {
                        if pickerTypes.count > 2 {
                            Picker("Type", selection: Binding(
                                get: { selection.type },
                                set: { type in
                                    var next = selection
                                    next.type = type
                                    Task { await apply(next, rt, info) }
                                }
                            )) {
                                ForEach(pickerTypes, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .disabled(pending != nil)
                        }
                        Spacer()
                        if pending != nil { ProgressView() }
                        if !caps.sorts.isEmpty {
                            Menu {
                                ForEach(caps.sorts, id: \.self) { s in
                                    Button {
                                        var next = selection
                                        next.order = s
                                        Task { await apply(next, rt, info) }
                                    } label: {
                                        if s == selection.order {
                                            Label(Self.label(for: s), systemImage: "checkmark")
                                        } else {
                                            Text(Self.label(for: s))
                                        }
                                    }
                                }
                            } label: { Label(selection.order.map(Self.label(for:)) ?? "Sort", systemImage: "arrow.up.arrow.down") }
                            .disabled(pending != nil)
                        }
                    }
                }

                if let feed {
                    FeedGrid(feed: feed)
                }
            }
            .padding()
        }
        .navigationTitle(info.name)
    }

    private func header(_ rt: PluginRuntime, _ info: ChannelInfo) -> some View {
        let channelURL = info.url.isEmpty ? url : info.url
        return VStack(alignment: .leading, spacing: 10) {
            if let b = info.banner, let u = URL(string: b) {
                RemoteImage(url: u).frame(height: 100).frame(maxWidth: .infinity).clipped()
            }
            HStack(spacing: 12) {
                RemoteImage(url: info.thumbnail.flatMap(URL.init(string:))).frame(width: 64, height: 64).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.title3.bold())
                    if let s = info.subscribers, s > 0 { Text("\(Fmt.count(s)) subscribers").font(.caption).foregroundStyle(.secondary) }
                    Text(rt.config.name).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    if app.library.isSubscribed(channelURL) { app.library.unsubscribe(channelURL) }
                    else {
                        var i = info; i.url = channelURL
                        app.library.subscribe(channel: i, pluginId: rt.id)
                    }
                } label: {
                    Text(app.library.isSubscribed(channelURL) ? "Subscribed" : "Subscribe")
                }
                .buttonStyle(.borderedProminent)
                .tint(app.library.isSubscribed(channelURL) ? .gray : .accentColor)
            }
            .padding(.horizontal)
            if let d = info.description, !d.isEmpty {
                Text(d).font(.footnote).lineLimit(expanded ? nil : 3).padding(.horizontal)
                    .onTapGesture { expanded.toggle() }
            }
            if !info.links.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(info.links.sorted(by: { $0.key < $1.key }), id: \.key) { name, link in
                            if let u = URL(string: link) { Link(name, destination: u).font(.caption).buttonStyle(.bordered) }
                        }
                    }.padding(.horizontal)
                }
            }
        }
    }

    private func load() async {
        loadState = .loading
        do {
            let (rt, info) = try await app.platform.channel(url: url)
            caps = await app.platform.channelCapabilities(rt)
            selection = ChannelFeedSelection()
            pending = nil
            loadState = .loaded(rt, info)
            await reloadFeed(rt, info, selection)
        } catch { loadState = .failed(error.localizedDescription) }
    }

    /// Loads `next`; the controls show it only once it has loaded. On failure they
    /// keep the previous choice, whose items stay on screen under the failure.
    private func apply(_ next: ChannelFeedSelection, _ rt: PluginRuntime, _ info: ChannelInfo) async {
        guard pending == nil, next != selection else { return }
        pending = next
        let outcome = await reloadFeed(rt, info, next)
        if outcome == .refreshed { selection = next }
        // A superseded load belongs to a newer request (another channel), which owns `pending`.
        if outcome != .superseded { pending = nil }
    }

    @discardableResult
    private func reloadFeed(_ rt: PluginRuntime, _ info: ChannelInfo, _ choice: ChannelFeedSelection) async -> FeedReloadOutcome {
        let f = feed ?? app.makeFeed()
        feed = f
        let channelURL = info.url.isEmpty ? url : info.url
        let types = ChannelFeedPlan.types(advertised: caps.types, selection: choice.type)
        let sources = types.map { type in
            app.platform.channelSource(
                runtime: rt, url: channelURL, type: type, order: choice.order,
                label: types.count > 1 ? "\(rt.config.name) (\(Self.label(for: type ?? ChannelFeedPlan.all)))" : nil
            )
        }
        return await f.reload(sources: sources, order: ChannelFeedPlan.feedOrder(sourceCount: sources.count, sort: choice.order))
    }

    static func label(for token: String) -> String {
        switch token {
        case ChannelFeedPlan.all: return "All"
        case "VIDEOS": return "Videos"
        case "STREAMS": return "Streams"
        case "LIVE": return "Live"
        case "POSTS": return "Posts"
        case "MIXED": return "All"
        case "SHORTS": return "Shorts"
        case "SUBSCRIPTIONS": return "Subscriptions"
        case "CHRONOLOGICAL": return "Newest first"
        default:
            let cleaned = token.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "_", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
        }
    }
}

/// The type and sort a channel feed shows.
struct ChannelFeedSelection: Equatable {
    var type = ChannelFeedPlan.all
    var order: String?
}

/// Which content types make up a channel's feed.
enum ChannelFeedPlan {
    /// The picker's "All": the channel's main feed.
    static let all = ""

    /// Types to load for `selection`; nil asks the plugin for its default feed.
    /// "All" uses the plugin's mixed feed when it has one. Otherwise it merges the
    /// types a channel's main feed is expected to hold, videos and streams (live
    /// only when there are no streams), and falls back to the first advertised
    /// type when the plugin offers none of those (posts or shorts only).
    static func types(advertised: [String], selection: String) -> [String?] {
        if selection != all { return [selection == "MIXED" ? nil : selection] }
        if advertised.isEmpty || advertised.contains("MIXED") { return [nil] }
        var main = advertised.filter { $0 == "VIDEOS" || $0 == "STREAMS" }
        if !advertised.contains("STREAMS"), advertised.contains("LIVE") { main.append("LIVE") }
        return main.isEmpty ? [advertised[0]] : main
    }

    /// Picker entries: "All" first, then each advertised type to narrow to.
    static func pickerTypes(advertised: [String]) -> [String] {
        [all] + advertised.filter { $0 != "MIXED" }
    }

    /// Several types merge into one newest-first timeline unless the user picked a
    /// sort other than chronological, which only the plugin can apply.
    static func feedOrder(sourceCount: Int, sort: String?) -> FeedOrder {
        sourceCount > 1 && (sort == nil || sort == "CHRONOLOGICAL") ? .newestFirst : .interleaved
    }
}

// MARK: - Remote playlist

@MainActor
struct PlaylistView: View {
    let url: String
    @Environment(AppModel.self) private var app
    @State private var title = "Playlist"
    @State private var header: ContentItem?
    @State private var feed: FeedModel?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Group {
            if let error { LoadingErrorView(message: error) { Task { await load() } } }
            else if let feed {
                FeedList(feed: feed, leadingIsEmpty: header == nil) {
                    if let header {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(header.name).font(.title3.bold())
                                if let a = header.author { Text(a.name).font(.subheadline).foregroundStyle(.secondary) }
                                if let n = header.videoCount, n >= 0 { Text("\(n) videos").font(.caption).foregroundStyle(.secondary) }
                                Button { Task { await save(feed, header) } } label: {
                                    Label(saving ? "Saving…" : "Save to library", systemImage: "square.and.arrow.down")
                                }.buttonStyle(.bordered).disabled(saving)
                            }
                        }.hiddenListRowSeparator()
                    }
                }
            } else { ProgressView() }
        }
        .navigationTitle(title)
        .detailNavigationStyle()
        .task(id: url) { await load() }
    }

    private func load() async {
        error = nil
        do {
            let (rt, payload, pager) = try await app.platform.playlist(url: url)
            header = payload.header
            title = payload.header.name
            let f = app.makeFeed()
            feed = f
            await f.reload(sources: [FeedSource(runtime: rt, label: rt.config.name) { pager }])
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ feed: FeedModel, _ header: ContentItem) async {
        saving = true
        let videos = await feed.loadAll(maxRounds: 25).filter { $0.kind == .video || $0.kind == .nested }.map { SavedVideo($0) }
        app.library.createPlaylist(name: header.name, videos: videos)
        saving = false
    }
}
