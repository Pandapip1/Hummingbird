import Foundation
import DebugKit
import SwiftOpenUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Home

@MainActor
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            Group {
                if app.plugins.enabledPlugins.isEmpty { NoSourcesView() }
                else if app.homeFeed.loadedOnce {
                    FeedList(feed: app.homeFeed, emptyTitle: "Nothing to show", emptyMessage: "Your sources returned no home feed.")
                        .refreshable { await app.loadHome(force: true) }
                } else { ProgressView() }
            }
            .navigationTitle("Home")
        }
        .task(id: app.plugins.enabledPlugins.map(\.id)) { await app.loadHome() }
    }
}

// MARK: - Search

@MainActor
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openRoute) private var openRoute
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var feed: FeedModel?
    @State private var channels: [ContentItem] = []
    @State private var suggestions: [String] = []
    @State private var searchGeneration = 0
    @State private var notice: String?
    @State private var pendingURL: String?

    var body: some View {
        NavigationStack {
            Group {
                if app.plugins.enabledPlugins.isEmpty { NoSourcesView() }
                else if let feed, query.trimmingCharacters(in: .whitespacesAndNewlines) == submittedQuery {
                    List {
                        if !channels.isEmpty {
                            Section("Channels") {
                                ForEach(channels.prefix(5)) { ContentRow(item: $0) }
                            }
                        }
                        Section(channels.isEmpty ? "" : "Videos") {
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
                    .overlay {
                        if feed.loadedOnce && feed.items.isEmpty && channels.isEmpty && !feed.isLoading {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if app.searchHistory.queries.isEmpty {
                        ContentUnavailableView("Search your sources", systemImage: "magnifyingglass",
                                               description: Text("Type a search, or paste a link to open it directly."))
                    } else {
                        List {
                            Section("Recent searches") {
                                ForEach(app.searchHistory.queries, id: \.self) { value in
                                    Button { runSuggestion(value) } label: {
                                        Label(value, systemImage: "clock.arrow.circlepath")
                                    }
                                }
                                .onDelete { offsets in
                                    offsets.map { app.searchHistory.queries[$0] }
                                        .forEach(app.searchHistory.remove)
                                }
                                Button("Clear recent searches", role: .destructive) { app.searchHistory.clear() }
                            }
                        }
                    }
                } else {
                    List {
                        ForEach(suggestions, id: \.self) { value in
                            Button { runSuggestion(value) } label: {
                                Label(value, systemImage: "magnifyingglass")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search or paste a link")
            .onSubmit(of: .search) { Task { await submit() } }
            .task(id: query) { await updateSuggestions() }
            .overlay(alignment: .bottom) {
                if let notice { Text(notice).font(.footnote).padding(10).background(.thinMaterial, in: Capsule()).padding() }
            }
            .confirmationDialog("Open link as…", isPresented: Binding(
                get: { pendingURL != nil },
                set: { if !$0 { pendingURL = nil } }
            ), titleVisibility: .visible) {
                if let url = pendingURL {
                    Button("Video or Stream") { openRoute(.content(url), title: "Video"); pendingURL = nil }
                    Button("Channel") { openRoute(.channel(url), title: "Channel"); pendingURL = nil }
                    Button("Playlist") { openRoute(.playlist(url), title: "Playlist"); pendingURL = nil }
                }
                Button("Cancel", role: .cancel) { pendingURL = nil }
            } message: {
                Text("Choose the view to open. The link itself does not decide the content type.")
            }
        }
    }

    private func submit() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        submittedQuery = text
        channels = []
        notice = nil
        app.searchHistory.record(text)
        suggestions = []
        if text.contains("://") {
            let routes = await app.platform.recognizedRoutes(for: text)
            guard generation == searchGeneration else { return }
            DebugServer.record("routing", "manual_url_matches", fields: [
                "content": String(routes.contains(.content(text))),
                "channel": String(routes.contains(.channel(text))),
                "playlist": String(routes.contains(.playlist(text))),
            ])
            if routes.count == 1, let route = routes.first {
                openRoute(route)
            } else if routes.isEmpty {
                notice = "None of your sources recognise that link."
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if generation == searchGeneration { notice = nil }
            } else {
                pendingURL = text
            }
            return
        }
        let f = app.makeFeed()
        feed = f
        async let found = app.platform.searchChannels(query: text)
        await f.reload(sources: app.platform.searchSources(query: text, type: nil, order: nil))
        let foundChannels = await found.map { $0.1 }
        guard generation == searchGeneration else { return }
        channels = foundChannels
    }

    private func runSuggestion(_ value: String) {
        query = value
        Task { await submit() }
    }

    private func updateSuggestions() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != submittedQuery else { suggestions = []; return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        let values = await app.platform.searchSuggestions(query: text)
        guard !Task.isCancelled,
              query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        suggestions = values
    }
}

// MARK: - Subscriptions

@MainActor
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            let feed = app.subscriptionFeed
            Group {
                if app.library.subscriptions.isEmpty {
                    ContentUnavailableView("No subscriptions", systemImage: "rectangle.stack.person.crop",
                                           description: Text("Open a channel and tap Subscribe, or import subscriptions from a source you are signed in to."))
                } else {
                    List {
                        ForEach(feed.visibleItems) { item in
                            ContentRow(item: item).hiddenListRowSeparator()
                                .onAppear { if item.id == feed.visibleItems.last?.id, feed.hasMoreToShow { feed.showMore() } }
                        }
                        if !feed.failures.isEmpty {
                            Section("Some channels failed") {
                                ForEach(feed.failures.sorted(by: { $0.key < $1.key }), id: \.key) { url, msg in
                                    VStack(alignment: .leading) {
                                        Text(url).font(.caption.bold()).lineLimit(1)
                                        Text(msg).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if feed.isRefreshing { ProgressView().frame(maxWidth: .infinity) }
                    }
                    .listStyle(.plain)
                    .refreshable { await feed.refresh() }
                }
            }
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { ManageSubscriptionsView() } label: { Image(systemName: "person.2") }
                }
            }
        }
        .task { if app.subscriptionFeed.lastRefresh == nil && !app.library.subscriptions.isEmpty { await app.subscriptionFeed.refresh() } }
    }
}

@MainActor
struct ManageSubscriptionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        List {
            ForEach(app.library.subscriptions) { sub in
                Button { openRoute(.channel(sub.channelURL), title: sub.name) } label: {
                    HStack(spacing: 12) {
                        RemoteImage(url: sub.thumbnail.flatMap(URL.init(string:))).frame(width: 40, height: 40).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(sub.name).font(.headline)
                            Text(app.plugins.plugin(sub.pluginId)?.config.name ?? "Unknown source").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                #if !os(tvOS)
                .swipeActions { Button("Unsubscribe", role: .destructive) { app.library.unsubscribe(sub.channelURL) } }
                #endif
            }
        }
        .navigationTitle("Manage")
        .overlay { if app.library.subscriptions.isEmpty { ContentUnavailableView("No subscriptions", systemImage: "person.2") } }
    }
}

// MARK: - Library

@MainActor
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PlaybackQueueView() } label: {
                        Label("Queue (\(app.playbackQueue.items.count))", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    NavigationLink { WatchLaterView() } label: { Label("Watch later (\(app.library.watchLater.count))", systemImage: "clock") }
                    NavigationLink { HistoryView() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                }
                Section("Playlists") {
                    ForEach(app.library.playlists) { p in
                        NavigationLink { LocalPlaylistView(playlistID: p.id) } label: {
                            HStack { Text(p.name); Spacer(); Text("\(p.videos.count)").foregroundStyle(.secondary) }
                        }
                    }
                    .onDelete { offsets in offsets.map { app.library.playlists[$0].id }.forEach { app.library.deletePlaylist($0) } }
                    Button { showNewPlaylist = true } label: { Label("New playlist", systemImage: "plus") }
                }
                #if !os(tvOS)
                Section("Backup") {
                    if let url = backupFile() {
                        ShareLink(item: url) { Label("Export library", systemImage: "square.and.arrow.up") }
                    }
                    Button { showImporter = true } label: { Label("Import library", systemImage: "square.and.arrow.down") }
                    if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                #endif
            }
            .navigationTitle("Library")
            .alert("New playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { app.library.createPlaylist(name: name) }
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) { newPlaylistName = "" }
            }
            #if !os(tvOS)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let backup = try? JSONDecoder().decode(LibraryBackup.self, from: data) {
                    app.library.merge(backup)
                    importMessage = "Imported \(backup.subscriptions.count) subscriptions, \(backup.playlists.count) playlists. Plugins listed in the backup must be added from Sources."
                } else { importMessage = "That file is not a Hummingbird library export." }
            }
            #endif
        }
    }

    private func backupFile() -> URL? {
        let backup = app.library.makeBackup(pluginSources: app.plugins.sourceMap)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(backup) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Hummingbird Library.json")
        try? data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
struct PlaybackQueueView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        List {
            ForEach(app.playbackQueue.items) { video in
                HStack(spacing: 8) {
                    Button { openRoute(.item(ContentItem(saved: video)), title: video.name) } label: {
                        HStack(spacing: 8) {
                        if video.id == app.playbackQueue.currentID {
                            Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(video.name).lineLimit(2)
                            if let author = video.authorName { Text(author).font(.caption).foregroundStyle(.secondary) }
                        }
                        }
                    }
                    Spacer()
                    Button { app.playbackQueue.moveUp(video) } label: { Image(systemName: "chevron.up") }
                    Button { app.playbackQueue.moveDown(video) } label: { Image(systemName: "chevron.down") }
                    Button { app.playbackQueue.remove(video) } label: { Image(systemName: "trash") }
                }
                .buttonStyle(.plain)
            }
            .onDelete { app.playbackQueue.remove(at: $0) }
            .onMove { app.playbackQueue.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { app.playbackQueue.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                    .disabled(app.playbackQueue.items.count < 2)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { app.playbackQueue.cycleRepeatMode() } label: {
                    Image(systemName: app.playbackQueue.repeatMode.systemImage)
                }
                .accessibilityLabel(app.playbackQueue.repeatMode.label)
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            #endif
        }
        .overlay {
            if app.playbackQueue.items.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward",
                                       description: Text("Add videos with Play next or Queue."))
            }
        }
    }
}

@MainActor
struct WatchLaterView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            ForEach(app.library.watchLater) { v in ContentRow(item: ContentItem(saved: v)) }
                .onDelete { app.library.removeWatchLater(at: $0) }
                .onMove { app.library.moveWatchLater(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .navigationTitle("Watch later")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        #endif
        .overlay { if app.library.watchLater.isEmpty { ContentUnavailableView("Nothing saved", systemImage: "clock", description: Text("Use \"Watch later\" on any video.")) } }
    }
}

@MainActor
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            ForEach(app.library.history) { h in
                VStack(alignment: .leading, spacing: 2) {
                    ContentRow(item: ContentItem(saved: h.video))
                    Text("Watched \(Fmt.relative(h.date))" + (h.position > 1 ? " · stopped at \(Fmt.duration(Int(h.position)))" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .onDelete { app.library.removeHistory(at: $0) }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .toolbar {
            if !app.library.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", role: .destructive) { app.library.clearHistory() }
                }
            }
        }
        .overlay { if app.library.history.isEmpty { ContentUnavailableView("No history", systemImage: "clock.arrow.circlepath") } }
    }
}

@MainActor
struct LocalPlaylistView: View {
    @Environment(AppModel.self) private var app
    let playlistID: UUID

    var body: some View {
        let playlist = app.library.playlists.first { $0.id == playlistID }
        List {
            ForEach(playlist?.videos ?? []) { v in ContentRow(item: ContentItem(saved: v)) }
                .onDelete { app.library.removeVideos(at: $0, from: playlistID) }
                .onMove { app.library.moveVideos(from: $0, to: $1, in: playlistID) }
        }
        .listStyle(.plain)
        .navigationTitle(playlist?.name ?? "Playlist")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
        #endif
        .overlay { if playlist?.videos.isEmpty ?? true { ContentUnavailableView("Empty playlist", systemImage: "music.note.list") } }
    }
}
