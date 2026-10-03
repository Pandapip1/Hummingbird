import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

@MainActor
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: contentMode)
            case .failure: Color.secondary.opacity(0.15).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            default: Color.secondary.opacity(0.1)
            }
        }
    }
}

/// A feed entry. Opens the right screen for the kind of content.
@MainActor
struct ContentRow: View {
    let item: ContentItem

    var body: some View {
        Group {
            switch item.kind {
            case .locked:
                if let u = item.unlockUrl.flatMap(URL.init(string:)) { PortableLink(destination: u) { card } } else { card }
            case .channel: NavigationLink(value: Route.channel(item.url)) { channelCard }
            case .playlist: NavigationLink(value: Route.playlist(item.url)) { card }
            default: NavigationLink(value: Route.item(item)) { card }
            }
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: item.thumbnailURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            HStack(alignment: .top, spacing: 10) {
                if let a = item.author, let t = a.thumbnail, let u = URL(string: t) {
                    RemoteImage(url: u).frame(width: 34, height: 34).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var channelCard: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.thumbnailURL).frame(width: 52, height: 52).clipShape(Circle())
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                if let s = item.subscribers, s > 0 { Text("\(Fmt.count(s)) subscribers").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if item.isLive {
            Text("LIVE").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.red, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if let d = item.duration, d > 0 {
            Text(Fmt.duration(d)).font(.caption2.monospacedDigit().bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if item.kind == .playlist, let n = item.videoCount, n >= 0 {
            Label("\(n)", systemImage: "list.bullet").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let n = item.author?.name, !n.isEmpty { parts.append(n) }
        if let v = item.viewCount, v >= 0, item.kind == .video { parts.append("\(Fmt.count(v)) views") }
        if let d = item.date { parts.append(Fmt.relative(d)) }
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct FeedList: View {
    let feed: FeedModel
    var emptyTitle = "Nothing here yet"
    var emptyMessage = "Pull down to refresh."

    var body: some View {
        List {
            ForEach(feed.items) { item in
                ContentRow(item: item)
                    .listRowSeparator(.hidden)
                    .onAppear { if item.id == feed.items.last?.id { Task { await feed.loadMore() } } }
            }
            ForEach(feed.messages, id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            if feed.isLoading { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
        }
        .listStyle(.plain)
        .overlay {
            if feed.loadedOnce && feed.items.isEmpty && !feed.isLoading && feed.messages.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyMessage))
            }
        }
    }
}

@MainActor
struct NoSourcesView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ContentUnavailableView {
            Label("No sources yet", systemImage: "puzzlepiece.extension")
        } description: {
            Text("Hummingbird gets its content from plugins. Add a source by pasting its URL or scanning its QR code.")
        } actions: {
            Button("Add a source") { app.selectedTab = .sources }.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// Registers the screens every tab can navigate to.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .content(let url): VideoDetailView(url: url, preview: nil)
            case .item(let item):
                switch item.kind {
                case .channel: ChannelView(url: item.url)
                case .playlist: PlaylistView(url: item.url)
                default: VideoDetailView(url: item.openURL, preview: item)
                }
            case .channel(let url): ChannelView(url: url)
            case .playlist(let url): PlaylistView(url: url)
            case .plugin(let id): PluginDetailView(pluginID: id)
            }
        }
    }
}

@MainActor
struct LoadingErrorView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: { Text(message) } actions: {
            if let retry { Button("Try again", action: retry) }
        }
    }
}


/// `Link` with an arbitrary label. SwiftOpenUI's `Link` only takes a title, so there it is a button that opens the URL.
@MainActor
struct PortableLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if canImport(SwiftUI)
        Link(destination: destination, label: label)
        #else
        Button { SystemServices.openURL(destination) } label: { label() }
        #endif
    }
}

/// `LazyVStack` taking arbitrary content. SwiftOpenUI's is data-driven, so there the content is a plain `VStack`
/// (the parent `ScrollView` still scrolls; only lazy realisation is lost).
@MainActor
struct PortableLazyVStack<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if canImport(SwiftUI)
        LazyVStack(alignment: alignment, spacing: spacing.map { Int($0) } ?? 8, content: content)
        #else
        VStack(alignment: alignment, spacing: spacing.map { Int($0) } ?? 8, content: content)
        #endif
    }
}
