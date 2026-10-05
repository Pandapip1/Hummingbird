import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

// MARK: - Channel

@MainActor
struct ChannelView: View {
    let url: String
    @Environment(AppModel.self) private var app
    @State private var loadState: LoadState = .loading
    @State private var feed: FeedModel?
    @State private var caps = ResultCapabilities()
    @State private var type: String?
    @State private var order: String?
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private func content(_ rt: PluginRuntime, _ info: ChannelInfo) -> some View {
        List {
            Section { header(rt, info) }.hiddenListRowSeparator().listRowInsets(EdgeInsets())

            if caps.types.count > 1 || !caps.sorts.isEmpty {
                Section {
                    HStack {
                        if caps.types.count > 1 {
                            Picker("Type", selection: Binding(get: { type ?? caps.types.first ?? "" }, set: { type = $0; Task { await reloadFeed(rt, info) } })) {
                                ForEach(caps.types, id: \.self) { Text(Self.label(for: $0)).tag($0) }
                            }.pickerStyle(.menu)
                        }
                        Spacer()
                        if !caps.sorts.isEmpty {
                            Menu {
                                ForEach(caps.sorts, id: \.self) { s in
                                    Button(Self.label(for: s)) { order = s; Task { await reloadFeed(rt, info) } }
                                }
                            } label: { Label(order.map(Self.label(for:)) ?? "Sort", systemImage: "arrow.up.arrow.down") }
                        }
                    }
                }
            }

            if let feed {
                ForEach(feed.items) { item in
                    ContentRow(item: item).hiddenListRowSeparator()
                        .loadsNextPageWhenLast(item.id == feed.items.last?.id) { await feed.loadMore() }
                }
                ForEach(feed.messages, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                if feed.isLoading { ProgressView().frame(maxWidth: .infinity) }
                LoadMoreButton(feed: feed)
            }
        }
        .listStyle(.plain)
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
            type = caps.types.first
            order = nil
            loadState = .loaded(rt, info)
            await reloadFeed(rt, info)
        } catch { loadState = .failed(error.localizedDescription) }
    }

    private func reloadFeed(_ rt: PluginRuntime, _ info: ChannelInfo) async {
        let f = feed ?? app.makeFeed()
        feed = f
        let source = app.platform.channelSource(runtime: rt, url: info.url.isEmpty ? url : info.url,
                                                type: type == "MIXED" ? nil : type, order: order)
        await f.reload(sources: [source])
    }

    static func label(for token: String) -> String {
        switch token {
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
                List {
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
                    ForEach(feed.items) { item in
                        ContentRow(item: item).hiddenListRowSeparator()
                            .loadsNextPageWhenLast(item.id == feed.items.last?.id) { await feed.loadMore() }
                    }
                    if feed.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    LoadMoreButton(feed: feed)
                }
                .listStyle(.plain)
            } else { ProgressView() }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        var rounds = 0
        while feed.hasMore, rounds < 25 { await feed.loadMore(); rounds += 1 }
        let videos = feed.items.filter { $0.kind == .video || $0.kind == .nested }.map { SavedVideo($0) }
        app.library.createPlaylist(name: header.name, videos: videos)
        saving = false
    }
}
