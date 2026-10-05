import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

@MainActor
struct VideoDetailView: View {
    let url: String
    let preview: ContentItem?

    @Environment(AppModel.self) private var app
    @State private var player = PlayerModel()
    @State private var state: LoadState = .loading
    @State private var tab: DetailTab = .about
    @State private var showPlaylistPicker = false
    @State private var activeURL: String
    @State private var activePreview: ContentItem?

    nonisolated init(url: String, preview: ContentItem?) {
        self.url = url
        self.preview = preview
        _activeURL = State(wrappedValue: url)
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: activeURL) {
            player.onPlaybackEnded = advanceQueue
            await load()
        }
        .onDisappear {
            player.onPlaybackEnded = nil
            player.teardown()
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if case .video(_, let d) = state { PlaylistPicker(video: SavedVideo(d.item)) }
        }
    }

    private func load() async {
        state = .loading
        var displayedCache = false
        if let (runtime, cached) = await app.platform.cachedDetails(url: activeURL) {
            displayedCache = true
            await display(cached, runtime: runtime, loadPlayer: true)
        }
        do {
            let (rt, details) = try await app.platform.details(url: activeURL)
            await display(details, runtime: rt, loadPlayer: !displayedCache)
        } catch {
            if !displayedCache { state = .failed(error.localizedDescription) }
        }
    }

    private func display(_ details: ContentDetails, runtime: PluginRuntime, loadPlayer: Bool) async {
        switch details {
        case .video(let video):
            state = .video(runtime, video)
            app.playbackQueue.beginPlaying(SavedVideo(video.item))
            if loadPlayer { await player.load(details: video, runtime: runtime, library: app.library) }
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
    @State private var descriptionExpanded = false

    var body: some View {
        let item = details.item
        let saved = SavedVideo(item)
        VStack(alignment: .leading, spacing: 12) {
            PlayerSection(model: player, width: playerWidth, height: playerHeight)

            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.title3.bold()).lineLimit(nil)
                Text(statsLine).font(.footnote).foregroundStyle(.secondary).lineLimit(nil)

                if let author = item.author, !author.url.isEmpty {
                    NavigationLink(value: Route.channel(author.url)) {
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
                        #if !os(tvOS)
                        if let share = URL(string: item.shareUrl ?? item.url) {
                            ShareLink(item: share) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        #endif
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
enum PlayerLayout {
    static let controlBarMinimumHeight: CGFloat = 44
    static let minimumBarSeparation: CGFloat = 24
    // Two bars, their 9-point vertical padding, the outer 8-point padding,
    // and the spacer plus two 6-point gaps between the bars.
    static let minimumHeight = 2 * (controlBarMinimumHeight + 2 * 9) + 2 * 8 + 2 * 6 + minimumBarSeparation

    static func usesStackedTransport(width: CGFloat) -> Bool { width < 600 }
    static func usesStackedTrackMenus(width: CGFloat) -> Bool { width < 280 }

    static func minimumHeight(width: CGFloat) -> CGFloat {
        let extraTransportRows: CGFloat = usesStackedTransport(width: width) ? 2 : 0
        let extraTrackRows: CGFloat = usesStackedTrackMenus(width: width) ? 1 : 0
        return minimumHeight + (extraTransportRows + extraTrackRows) * (controlBarMinimumHeight + 6)
    }

    static func height(width: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let minimumHeight = minimumHeight(width: width)
        // In a very short window the controls minimum takes precedence; the page scrolls.
        let limit = max(minimumHeight, viewportHeight * 0.9)
        return min(max(minimumHeight, width * 9 / 16), limit)
    }
}

@MainActor
struct PlayerSection: View {
    let model: PlayerModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        #if canImport(UIKit) || os(macOS)
        player
        #else
        let isFullscreen = model.isFullscreen
        player.fullScreenCover(
            isPresented: Binding(get: { isFullscreen }, set: { if !$0 { model.dismissFullscreen() } })
        ) {
            FullscreenPlayerView(model: model)
        }
        #endif
    }

    private var player: some View {
        ZStack {
            Color.black
            if model.hasMedia { PlayerSurface(model: model) }
            if model.isPreparing { ProgressView().tint(.white) }
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

@MainActor
struct PlayerControls: View {
    let model: PlayerModel
    let isFullscreen: Bool
    var availableWidth: CGFloat = .infinity
    @State private var controlsVisible = true
    @State private var autoHide = PlayerControlsAutoHide()

    var body: some View {
        ZStack {
            Color.clear.onTapGesture { interacted() }

            if let text = model.subtitleText {
                Text(text)
                    .font(.system(size: model.subtitleSizeChoice.rawValue).weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(model.subtitleColorChoice.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, controlsVisible ? (PlayerLayout.usesStackedTransport(width: availableWidth) ? 178 : 78) : 16)
            }

            if controlsVisible || !model.isPlaying {
                VStack(spacing: 6) {
                    trackControls
                    .foregroundStyle(Color.white)
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8)

                    Spacer()
                        .frame(minHeight: PlayerLayout.minimumBarSeparation, maxHeight: .infinity)

                    transportControls
                    .foregroundStyle(Color.white)
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8)
                }
                .padding(.vertical, 8)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { interacted() }
        }
        .task { interacted() }
        .onChange(of: model.isPlaying) { playing in
            if playing { interacted() }
            else { autoHide.task?.cancel(); if !controlsVisible { controlsVisible = true } }
        }
    }

    @ViewBuilder
    private var trackControls: some View {
        if PlayerLayout.usesStackedTrackMenus(width: availableWidth) {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    VideoMenu(model: model, interacted: interacted)
                    AudioMenu(model: model, interacted: interacted)
                }
                .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
                SubtitleMenu(model: model, interacted: interacted)
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
            }
        } else {
            HStack(spacing: 12) {
                if isFullscreen && !PlayerLayout.usesStackedTransport(width: availableWidth) {
                    Text(model.title).font(.headline)
                }
                Spacer()
                VideoMenu(model: model, interacted: interacted)
                AudioMenu(model: model, interacted: interacted)
                SubtitleMenu(model: model, interacted: interacted)
            }
        }
    }

    @ViewBuilder
    private var transportControls: some View {
        if PlayerLayout.usesStackedTransport(width: availableWidth) {
            VStack(spacing: 6) {
                HStack(spacing: 14) { transportButtons }
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
                PlayerTimeline(model: model, interacted: interacted)
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
                HStack(spacing: 14) { secondaryButtons }
                    .frame(minHeight: PlayerLayout.controlBarMinimumHeight)
            }
        } else {
            HStack(spacing: 14) {
                transportButtons
                PlayerTimeline(model: model, interacted: interacted)
                secondaryButtons
            }
        }
    }

    @ViewBuilder
    private var transportButtons: some View {
        Button { interacted(); model.skip(by: -10) } label: {
            Image(systemName: "gobackward.10").accessibilityLabel("Back 10 seconds")
        }
        Button { interacted(); model.togglePlayback() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        }
        Button { interacted(); model.skip(by: 10) } label: {
            Image(systemName: "goforward.10").accessibilityLabel("Forward 10 seconds")
        }
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if model.pictureInPictureSupported {
            Button { interacted(); model.startPictureInPicture() } label: {
                Image(systemName: "pip.enter").accessibilityLabel("Picture in Picture")
            }
        }
        Button { interacted(); model.toggleFullscreen() } label: {
            Image(systemName: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .accessibilityLabel(isFullscreen ? "Exit Full Screen" : "Enter Full Screen")
        }
        PlaybackSpeedMenu(model: model, interacted: interacted)
    }

    private func interacted() {
        if !controlsVisible { controlsVisible = true }
        autoHide.task?.cancel()
        guard model.isPlaying else { return }
        autoHide.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, model.isPlaying else { return }
            controlsVisible = false
        }
    }

}

/// Resetting the idle timer must not invalidate the controls under the pointer.
/// Only visibility belongs to view state; the task is an implementation detail.
@MainActor
private final class PlayerControlsAutoHide {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}

/// Playback ticks update this small subtree without replacing transport buttons
/// or menus while a pointer press or hover is in progress.
@MainActor
private struct PlayerTimeline: View {
    let model: PlayerModel
    let interacted: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(playbackTime).font(.caption.monospacedDigit())
            if model.duration > 0 {
                #if os(tvOS)
                ProgressView(value: min(model.playbackTime, model.duration), total: model.duration)
                    .frame(minWidth: 80, maxWidth: .infinity)
                #else
                Slider(value: Binding(
                    get: { min(model.playbackTime, model.duration) },
                    set: {
                        interacted()
                        model.seek(to: $0)
                    }
                ), in: 0...model.duration, onEditingChanged: { _ in interacted() })
                .frame(minWidth: 80, maxWidth: .infinity)
                #endif
            } else {
                Spacer()
            }
        }
    }

    private var playbackTime: String {
        let seconds = max(0, Int(model.playbackTime))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

}

@MainActor
private struct PlaybackSpeedMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    private let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Menu {
            ForEach(rates, id: \.self) { rate in
                Button { interacted(); model.setPlaybackRate(rate) } label: {
                    let label = rate == 1 ? "Normal" : "\(rate.formatted())×"
                    if rate == model.playbackRate { Label(label, systemImage: "checkmark") }
                    else { Text(label) }
                }
            }
        } label: {
            Text(model.playbackRate == 1 ? "Speed" : "\(model.playbackRate.formatted())×")
                .foregroundStyle(.white)
        }
    }
}

@MainActor
private struct VideoMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let tracks = model.tracks.filter { $0.kind == .video }
        if model.options.count > 1 || !tracks.isEmpty {
            Menu {
                ForEach(model.options) { option in
                    Button { interacted(); Task { await model.select(option) } } label: {
                        if option.id == model.selected?.id { Label(option.label, systemImage: "checkmark") }
                        else { Text(option.label) }
                    }
                }
                if model.options.count > 1 && !tracks.isEmpty { Divider() }
                ForEach(tracks, id: \.id) { track in
                    Button { interacted(); model.selectTrack(track) } label: {
                        let label = track.label ?? track.language ?? "Video"
                        if model.selectedTrack(ofKind: .video)?.id == track.id { Label(label, systemImage: "checkmark") }
                        else { Text(label) }
                    }
                }
            } label: { Text("Video") }
        }
    }
}

@MainActor
private struct AudioMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let tracks = model.tracks.filter { $0.kind == .audio }
        if !tracks.isEmpty {
            Menu {
                ForEach(tracks, id: \.id) { track in
                    Button { interacted(); model.selectTrack(track) } label: {
                        let label = track.label ?? track.language ?? "Audio"
                        if model.selectedTrack(ofKind: .audio)?.id == track.id { Label(label, systemImage: "checkmark") }
                        else { Text(label) }
                    }
                }
            } label: { Text("Audio") }
        }
    }
}

@MainActor
private struct SubtitleMenu: View {
    let model: PlayerModel
    let interacted: () -> Void
    var body: some View {
        let embedded = model.tracks.filter { $0.kind == .subtitles }
        if !model.subtitleSources.isEmpty || !embedded.isEmpty {
            Menu {
                Button { interacted(); Task { await model.chooseSubtitle(nil) } } label: {
                    if model.subtitleChoice == nil && model.embeddedSubtitleChoice == nil {
                        Label("Off", systemImage: "checkmark")
                    } else { Text("Off") }
                }
                ForEach(embedded, id: \.id) { track in
                    Button { interacted(); Task { await model.chooseEmbeddedSubtitle(track) } } label: {
                        let name = track.label ?? track.language ?? "Embedded"
                        if model.embeddedSubtitleChoice?.id == track.id {
                            Label(name, systemImage: "checkmark")
                        } else { Text(name) }
                    }
                }
                ForEach(model.subtitleSources) { s in
                    Button { interacted(); Task { await model.chooseSubtitle(s) } } label: {
                        if model.subtitleChoice?.id == s.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                    }
                }
                if model.embeddedSubtitleChoice == nil && !model.subtitleSources.isEmpty {
                    Divider()
                    ForEach(SubtitleColorChoice.allCases, id: \.rawValue) { choice in
                        Button { interacted(); model.setSubtitleColor(choice) } label: {
                            if model.subtitleColorChoice == choice {
                                Label("Caption Color: \(choice.label)", systemImage: "checkmark")
                            } else {
                                Text("Caption Color: \(choice.label)")
                            }
                        }
                    }
                    Divider()
                    ForEach(SubtitleSizeChoice.allCases, id: \.rawValue) { choice in
                        Button { interacted(); model.setSubtitleSize(choice) } label: {
                            if model.subtitleSizeChoice == choice {
                                Label("Caption Size: \(choice.label)", systemImage: "checkmark")
                            } else {
                                Text("Caption Size: \(choice.label)")
                            }
                        }
                    }
                }
            } label: { Text("Subtitles") }
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
        PortableLazyVStack(alignment: .leading, spacing: 14) {
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
        PortableLazyVStack(alignment: .leading) {
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
