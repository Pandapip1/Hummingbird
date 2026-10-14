import Foundation
import SwiftOpenUI
import AdvancedVideoPlayerKit
@MainActor
struct VideoDetailView: View {
    let url: String
    let preview: ContentItem?
    let shouldKeepPlaybackWhenHidden: () -> Bool

    @Environment(AppModel.self) private var app
    @Environment(\.isBrowserTabOverviewPreview) private var isOverviewPreview
    @State private var player: PlayerModel
    @State private var state: LoadState = .loading
    @State private var tab: DetailTab = .about
    @State private var showPlaylistPicker = false
    @State private var activeURL: String
    @State private var activePreview: ContentItem?

    init(url: String, preview: ContentItem?, player: PlayerModel,
         shouldKeepPlaybackWhenHidden: @escaping () -> Bool) {
        self.url = url
        self.preview = preview
        self.shouldKeepPlaybackWhenHidden = shouldKeepPlaybackWhenHidden
        _player = State(wrappedValue: player)
        _activeURL = State(wrappedValue: player.loadedURL ?? url)
        _activePreview = State(wrappedValue: preview)
    }

    enum LoadState { case loading, failed(String), video(PluginRuntime, VideoDetails), post(PostDetails), unsupported(ContentItem) }
    enum DetailTab: String, CaseIterable { case about = "About", comments = "Comments", related = "Related" }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                switch state {
                case .loading:
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle().fill(.secondary.opacity(0.15)).aspectRatio(16 / 9, contentMode: .fit)
                        Text(activePreview?.name ?? "Loading…").font(.title3.bold()).padding(.horizontal)
                        ProgressView().frame(maxWidth: .infinity)
                    }
                case .failed(let message):
                    LoadingErrorView(message: message) { Task { await load() } }.padding(.top, 60)
                case .video(let rt, let d):
                    VideoBody(runtime: rt, details: d, player: player, tab: $tab,
                              showPlaylistPicker: $showPlaylistPicker,
                              playerWidth: geometry.size.width,
                              playerHeight: PlayerLayout.height(width: geometry.size.width, viewportHeight: geometry.size.height))
                case .post(let p):
                    PostBody(post: p)
                case .unsupported(let item):
                    ContentUnavailableView("Can't open this", systemImage: "questionmark.square.dashed",
                                           description: Text("\"\(item.name)\" is a kind of content Hummingbird does not display yet."))
                }
            }
        }
        .immersiveVideoDetailStyle()
        .task(id: activeURL) {
            if !isOverviewPreview { player.onPlaybackEnded = advanceQueue }
            await load()
        }
        .onDisappear {
            guard !isOverviewPreview else { return }
            let disappearingURL = activeURL
            Task { @MainActor in
                // Let tab navigation update its route before deciding whether
                // this is merely a tab switch or the page really went away.
                await Task.yield()
                guard !shouldKeepPlaybackWhenHidden() else { return }
                // A replacement video view may already have reused this tab's
                // player. Never let the outgoing page tear down the new media.
                guard player.loadedURL == disappearingURL else { return }
                player.onPlaybackEnded = nil
                player.teardown()
            }
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if case .video(_, let d) = state { PlaylistPicker(video: SavedVideo(d.item)) }
        }
    }

    private func load() async {
        state = .loading
        var displayedCache = false
        let playerAlreadyLoaded = player.hasMedia && player.loadedURL == activeURL
        if let (runtime, cached) = await app.platform.cachedDetails(url: activeURL) {
            displayedCache = true
            // Persisted details are only a fast UI placeholder. Playback sources can
            // contain host ABI capabilities and JavaScript handles from the runtime
            // that created them, so they must never be used to construct a player.
            await display(cached, runtime: runtime, loadPlayer: false)
        }
        do {
            let (rt, details) = try await app.platform.details(url: activeURL)
            await display(details, runtime: rt, loadPlayer: !isOverviewPreview && !playerAlreadyLoaded)
        } catch {
            if !displayedCache { state = .failed(error.localizedDescription) }
        }
    }

    private func display(_ details: ContentDetails, runtime: PluginRuntime, loadPlayer: Bool) async {
        switch details {
        case .video(let video):
            state = .video(runtime, video)
            app.playbackQueue.beginPlaying(SavedVideo(video.item))
            if loadPlayer {
                await player.load(details: video, runtime: runtime, library: app.library, sourceURL: activeURL)
            }
        case .post(let post): state = .post(post)
        case .other(let item): state = .unsupported(item)
        }
    }

    private func advanceQueue() {
        guard let next = app.playbackQueue.advanceAfterPlayback() else { return }
        if next.url == activeURL {
            player.replay()
            return
        }
        activePreview = ContentItem(saved: next)
        activeURL = next.url
    }
}

// MARK: - Video body

@MainActor
private struct VideoBody: View {
    let runtime: PluginRuntime
    let details: VideoDetails
    let player: PlayerModel
    @Binding var tab: VideoDetailView.DetailTab
    @Binding var showPlaylistPicker: Bool
    let playerWidth: CGFloat
    let playerHeight: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(\.openRoute) private var openRoute
    @Environment(\.isBrowserTabOverviewPreview) private var isOverviewPreview
    @State private var descriptionExpanded = false

    var body: some View {
        let item = details.item
        let saved = SavedVideo(item)
        VStack(alignment: .leading, spacing: 12) {
            if isOverviewPreview {
                Rectangle()
                    .fill(.black)
                    .overlay { Image(systemName: "play.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.7)) }
                    .frame(width: playerWidth, height: playerHeight)
            } else {
                PlayerSection(model: player, width: playerWidth, height: playerHeight)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.title3.bold()).lineLimit(nil)
                Text(statsLine).font(.footnote).foregroundStyle(.secondary).lineLimit(nil)

                if let author = item.author, !author.url.isEmpty {
                    Button { openRoute(.channel(author.url), title: author.name) } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: author.thumbnail.flatMap(URL.init(string:))).frame(width: 36, height: 36).clipShape(Circle())
                            VStack(alignment: .leading) {
                                Text(author.name).font(.subheadline.weight(.semibold))
                                if let s = author.subscribers, s > 0 { Text("\(Fmt.count(s)) subscribers").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button { app.library.toggleWatchLater(saved) } label: {
                            Label(app.library.isInWatchLater(saved) ? "Saved" : "Watch later", systemImage: app.library.isInWatchLater(saved) ? "clock.badge.checkmark" : "clock")
                        }
                        Button { showPlaylistPicker = true } label: { Label("Playlist", systemImage: "text.badge.plus") }
                        ShareContentAction(item: URL(string: item.shareUrl ?? item.url)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }.buttonStyle(.bordered)
                }

                Picker("", selection: $tab) {
                    ForEach(VideoDetailView.DetailTab.allCases.filter { $0 != .comments || hasComments }, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            .padding(.horizontal)

            switch tab {
            case .about:
                VStack(alignment: .leading) {
                    Text(plain(details.description)).font(.subheadline).lineLimit(descriptionExpanded ? nil : 6)
                    if details.description.count > 280 { Button(descriptionExpanded ? "Show less" : "Show more") { descriptionExpanded.toggle() }.font(.footnote) }
                }.padding(.horizontal)
            case .comments:
                CommentsSection(runtime: runtime, details: details)
            case .related:
                RelatedSection(runtime: runtime, details: details)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasComments: Bool { details.hasComments || runtime.has("getComments") }

    private var statsLine: String {
        var p: [String] = []
        if let v = details.item.viewCount, v >= 0 { p.append("\(Fmt.count(v)) views") }
        if let d = details.item.date { p.append(Fmt.relative(d)) }
        if let r = details.rating {
            if let l = r.likes, l >= 0 { p.append("\(Fmt.count(l)) likes") }
        }
        return p.joined(separator: " · ")
    }

    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
}

// MARK: - Player

/// Reserve the player's complete footprint before laying out the metadata.
/// A maximum alone does not give a flexible video surface an ideal height in a scroll view.
typealias PlayerLayout = AdvancedVideoPlayerLayout

extension AdvancedVideoPlayerLayout {
    static func usesStackedTrackMenus(width: CGFloat) -> Bool {
        usesStackedAccessoryControls(width: width)
    }
}

@MainActor
struct PlayerSection: View {
    let model: PlayerModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        player
            .playerFullscreenPresentation(model: model)
    }

    private var player: some View {
        ZStack {
            Color.black
            if model.hasMedia { PlayerSurface(model: model) }
            if model.isPreparing {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    if let message = model.preparationMessage {
                        Text(message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                    }
                }
                .padding()
            }
            if let err = model.errorMessage {
                Text(err).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white).padding()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay {
            PlayerControls(model: model, isFullscreen: false, availableWidth: width)
        }
    }
}

@MainActor
struct FullscreenPlayerView: View {
    let model: PlayerModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                PlayerSurface(model: model)
                PlayerControls(model: model, isFullscreen: true, availableWidth: geometry.size.width)
            }
        }
    }
}

// MARK: - macOS fullscreen


@MainActor
struct PlayerControls: View {
    let model: PlayerModel
    let isFullscreen: Bool
    var availableWidth: CGFloat = .infinity

    var body: some View {
        ZStack {
            if let text = model.subtitleText {
                Text(text)
                    .font(.system(size: model.subtitleSizeChoice.rawValue).weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(model.subtitleColorChoice.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, PlayerLayout.usesStackedTransport(width: availableWidth) ? 178 : 128)
            }

            AdvancedVideoPlayerControls(
                model: model,
                isFullscreen: isFullscreen,
                availableWidth: availableWidth
            ) { interacted in
                HummingbirdPlayerAccessories(model: model, availableWidth: availableWidth, interacted: interacted)
            }
        }
    }
}

/// Hummingbird contributes source and track selection to the reusable player.
/// Other applications can supply entirely different accessory controls.
@MainActor
private struct HummingbirdPlayerAccessories: View {
    let model: PlayerModel
    let availableWidth: CGFloat
    let interacted: () -> Void

    var body: some View {
        if PlayerLayout.usesStackedAccessoryControls(width: availableWidth) {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    VideoMenu(model: model, interacted: interacted)
                    AudioMenu(model: model, interacted: interacted)
                }
                SubtitleMenu(model: model, interacted: interacted)
            }
        } else {
            VideoMenu(model: model, interacted: interacted)
            AudioMenu(model: model, interacted: interacted)
            SubtitleMenu(model: model, interacted: interacted)
        }
    }
}

@MainActor
private struct VideoMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let tracks = model.tracks.filter { $0.kind == .video }
        if model.options.count > 1 {
            VideoSourceControl(options: model.options, selectedID: model.selected?.id, label: \.label,
                               onSelect: { option in Task { await model.select(option) } }, interacted: interacted)
        }
        if !tracks.isEmpty {
            MediaTrackControl(title: "Video Track", tracks: tracks,
                              selectedID: model.selectedTrack(ofKind: .video)?.id, fallbackLabel: "Video",
                              onSelect: model.selectTrack, interacted: interacted)
        }
    }
}

@MainActor
private struct AudioMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let tracks = model.tracks.filter { $0.kind == .audio }
        if !model.audioSources.isEmpty {
            VideoSourceControl(title: "Audio", options: model.audioSources,
                               selectedID: model.selectedAudioSource?.id,
                               label: PlaybackSelector.audioLabel,
                               onSelect: { source in Task { await model.selectAudioSource(source) } },
                               interacted: interacted)
        } else if !tracks.isEmpty {
            MediaTrackControl(title: "Audio", tracks: tracks,
                              selectedID: model.selectedTrack(ofKind: .audio)?.id, fallbackLabel: "Audio",
                              onSelect: model.selectTrack, interacted: interacted)
        }
    }
}

@MainActor
private struct SubtitleMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let embedded = model.tracks.filter { $0.kind == .subtitles }
        let external = model.subtitleSources.map { SubtitleOption(id: $0.id, name: $0.name) }
        SubtitleControl(
            embedded: embedded,
            external: external,
            selectedEmbeddedID: model.embeddedSubtitleChoice?.id,
            selectedExternalID: model.subtitleChoice?.id,
            onSelectEmbedded: { track in Task { await model.chooseEmbeddedSubtitle(track) } },
            onSelectExternal: { option in
                let source = option.flatMap { selected in model.subtitleSources.first { $0.id == selected.id } }
                Task { await model.chooseSubtitle(source) }
            },
            interacted: interacted
        ) {
            if model.embeddedSubtitleChoice == nil && !model.subtitleSources.isEmpty {
                Divider()
                ForEach(SubtitleColorChoice.allCases, id: \.rawValue) { choice in
                    Button { interacted(); model.setSubtitleColor(choice) } label: {
                        if model.subtitleColorChoice == choice { Label("Caption Color: \(choice.label)", systemImage: "checkmark") }
                        else { Text("Caption Color: \(choice.label)") }
                    }
                }
                Divider()
                ForEach(SubtitleSizeChoice.allCases, id: \.rawValue) { choice in
                    Button { interacted(); model.setSubtitleSize(choice) } label: {
                        if model.subtitleSizeChoice == choice { Label("Caption Size: \(choice.label)", systemImage: "checkmark") }
                        else { Text("Caption Size: \(choice.label)") }
                    }
                }
            }
        }
    }
}

// MARK: - Comments

@MainActor
private struct CommentsSection: View {
    let runtime: PluginRuntime
    let details: VideoDetails
    @Environment(AppModel.self) private var app
    @State private var comments: [PluginComment] = []
    @State private var pager: PluginPager<PluginComment>?
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        LazyContentStack(alignment: .leading, spacing: 14) {
            ForEach(comments) { c in
                CommentRow(runtime: runtime, comment: c)
                    .onAppear { if c.id == comments.last?.id { Task { await more() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if !loading && comments.isEmpty && message == nil { Text("No comments").foregroundStyle(.secondary) }
        }
        .padding(.horizontal)
        .task {
            do {
                if let p = try await app.platform.comments(runtime: runtime, details: details) { pager = p; comments = p.initial }
            } catch { message = app.platform.surface(error, pluginID: runtime.id) }
            loading = false
        }
    }

    private func more() async {
        guard let pager, pager.hasMore, !loading else { return }
        loading = true
        if let next = try? await pager.next() { comments.append(contentsOf: next) }
        loading = false
    }
}

@MainActor
private struct CommentRow: View {
    let runtime: PluginRuntime
    let comment: PluginComment
    @State private var replies: [PluginComment]?
    @State private var loading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: comment.author.thumbnail.flatMap(URL.init(string:))).frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.name).font(.caption.bold())
                    if comment.date > 0 { Text(Fmt.relative(Date(timeIntervalSince1970: TimeInterval(comment.date)))).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(comment.message).font(.subheadline)
                if let l = comment.rating?.likes, l > 0 { Label(Fmt.count(l), systemImage: "hand.thumbsup").font(.caption2).foregroundStyle(.secondary) }
                if comment.replyCount > 0 && replies == nil {
                    Button(loading ? "Loading…" : "\(comment.replyCount) replies") { Task { await loadReplies() } }.font(.caption)
                }
                if let replies {
                    ForEach(replies) { CommentRow(runtime: runtime, comment: $0).padding(.leading, 6) }
                }
            }
        }
    }

    private func loadReplies() async {
        loading = true
        defer { loading = false }
        if let p = try? await runtime.subCommentsPager(handle: comment.handle) { replies = p.initial }
        else { replies = [] }
    }
}

// MARK: - Related

@MainActor
private struct RelatedSection: View {
    let runtime: PluginRuntime
    let details: VideoDetails
    @Environment(AppModel.self) private var app
    @State private var items: [ContentItem] = []
    @State private var loading = true

    var body: some View {
        LazyContentStack(alignment: .leading) {
            ForEach(items) { ContentRow(item: $0).padding(.horizontal) }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !loading && items.isEmpty { Text("No related videos").foregroundStyle(.secondary).padding(.horizontal) }
        }
        .task {
            if let p = await app.platform.recommendations(runtime: runtime, details: details) { items = p.initial }
            loading = false
        }
    }
}

// MARK: - Posts

@MainActor
private struct PostBody: View {
    let post: PostDetails
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(post.item.images, id: \.self) { RemoteImage(url: URL(string: $0), contentMode: .fit).frame(maxWidth: .infinity) }
            Text(post.item.name).font(.title2.bold())
            if let a = post.item.author { Text(a.name).font(.subheadline).foregroundStyle(.secondary) }
            // HTML is flattened to text; rich layout is not rendered.
            Text(flatten(post.content)).font(.body)
        }
        .padding()
    }

    private func flatten(_ s: String) -> String {
        guard post.textType == 1 else { return s }
        return s.replacingOccurrences(of: "</p>", with: "\n\n").replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Add to playlist

@MainActor
struct PlaylistPicker: View {
    let video: SavedVideo
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.library.playlists) { p in
                    Button {
                        app.library.add(video, to: p.id); dismiss()
                    } label: {
                        HStack { Text(p.name); Spacer()
                            if p.videos.contains(where: { $0.id == video.id }) { Image(systemName: "checkmark") } }
                    }
                }
                Section("New playlist") {
                    TextField("Name", text: $newName)
                    Button("Create and add") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        app.library.createPlaylist(name: name, videos: [video]); dismiss()
                    }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add to playlist")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
