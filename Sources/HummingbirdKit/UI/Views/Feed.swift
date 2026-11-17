import Foundation
import Observation
import os
import SwiftOpenUI

// A feed's items and its failed sources are one piece of content. The model
// keeps both `fileprivate`, so the only way to put a feed on screen is
// `FeedList` or `FeedGrid` below, and both render the failures above the
// results. A screen cannot show one source's items while another source's
// failure sits unseen below them (the Twitch search bug: its error was listed
// after YouTube's endless results).

private func capture<T: Sendable>(_ op: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await op()) } catch { return .failure(error) }
}

// MARK: - Failures

/// A source that could not deliver its part of a feed or search.
///
/// Created only through `record`, which writes the failure to the persisted
/// log, so every failure the user can see is also in the log.
struct SourceFailure: Identifiable, Equatable, Sendable {
    enum Stage: String, Sendable {
        case firstPage = "first_page", nextPage = "next_page", channels, suggestions

        /// What failed, for display after the source's name; nil for the main results.
        var detail: String? {
            switch self {
            case .firstPage: return nil
            case .nextPage: return "more results"
            case .channels: return "channels"
            case .suggestions: return "suggestions"
            }
        }
    }

    let pluginID: String
    /// Identifies the feed source; one plugin can feed several (a channel's videos and streams).
    let sourceKey: String
    let label: String
    let message: String
    let stage: Stage
    var id: String { "\(sourceKey)|\(stage.rawValue)" }

    private init(pluginID: String, sourceKey: String, label: String, message: String, stage: Stage) {
        self.pluginID = pluginID
        self.sourceKey = sourceKey
        self.label = label
        self.message = message
        self.stage = stage
    }

    /// Makes the failure and logs it. Plugin and service messages can carry
    /// tokens and addresses, so they are redacted before being logged as public.
    static func record(pluginID: String, sourceKey: String? = nil, label: String, message: String, stage: Stage) -> SourceFailure {
        let failure = SourceFailure(pluginID: pluginID, sourceKey: sourceKey ?? pluginID, label: label, message: message, stage: stage)
        Logger.plugin.error("feed_source_failed plugin=\(pluginID, privacy: .public) source=\(LogRedaction.redact(failure.sourceKey), privacy: .public) stage=\(stage.rawValue, privacy: .public) error=\(LogRedaction.redact(message), privacy: .public)")
        return failure
    }
}

/// One failed source, with a retry that goes pending (disabled, spinner) until
/// the retry finishes; the row then disappears or shows the new error.
@MainActor
struct SourceFailureRow: View {
    let failure: SourceFailure
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.stage.detail.map { "\(failure.label) (\($0))" } ?? failure.label)
                    .font(.footnote.bold())
                Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            Spacer()
            if isRetrying { ProgressView() }
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .disabled(isRetrying)
        }
    }
}

// MARK: - Model

/// How a feed combines its sources.
enum FeedOrder: Sendable, Equatable {
    /// Round-robin by page position, so no single source dominates (search, home).
    case interleaved
    /// One timeline, newest first. Each source must already be newest first;
    /// sources page independently and are merged as their pages arrive.
    case newestFirst
}

/// What a reload did, for controls that show the applied value only once it is real.
enum FeedReloadOutcome: Sendable, Equatable {
    /// At least one source delivered; the feed now shows the new request.
    case refreshed
    /// Every source failed; the feed keeps what it showed before.
    case failed
    /// A newer reload started before this one finished; its result was dropped.
    case superseded
}

struct FeedSource: Sendable {
    let runtime: PluginRuntime
    let label: String
    /// Distinguishes several sources from one plugin; defaults to the plugin ID.
    let key: String
    let open: @Sendable () async throws -> PluginPager<ContentItem>

    init(runtime: PluginRuntime, label: String, key: String? = nil,
         open: @escaping @Sendable () async throws -> PluginPager<ContentItem>) {
        self.runtime = runtime
        self.label = label
        self.key = key ?? runtime.id
        self.open = open
    }
}

/// Loads pages from several plugins and combines them in `order`.
@MainActor
@Observable
final class FeedModel {
    fileprivate private(set) var items: [ContentItem] = []
    fileprivate private(set) var failures: [SourceFailure] = []
    fileprivate private(set) var retrying: Set<String> = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var loadedOnce = false

    private final class Feeder {
        let source: FeedSource
        let pager: PluginPager<ContentItem>
        /// Items fetched but not yet placed (newest-first merging holds them back
        /// until every other source has caught up).
        var buffer: [ContentItem] = []
        /// Its last page failed; it no longer holds back the merge until retried.
        var stalled = false
        init(source: FeedSource, pager: PluginPager<ContentItem>) { self.source = source; self.pager = pager }
        var hasMore: Bool { pager.hasMore }
    }

    @ObservationIgnored private var sources: [FeedSource] = []
    @ObservationIgnored private var order: FeedOrder = .interleaved
    @ObservationIgnored private var feeders: [Feeder] = []
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retryActions: [String: @MainActor () async -> Void] = [:]
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

    // MARK: data access outside views

    /// Everything loaded so far, for code that consumes the feed as data (saving a
    /// playlist, tests). Views render a feed with `FeedList` or `FeedGrid`.
    struct Content: Equatable {
        let failures: [SourceFailure]
        let items: [ContentItem]
    }
    var content: Content { Content(failures: failures, items: items) }

    /// Pages through every source (bounded) and returns all items, e.g. to save a playlist.
    func loadAll(maxRounds: Int) async -> [ContentItem] {
        var rounds = 0
        while hasMore, rounds < maxRounds { await loadMore(); rounds += 1 }
        return items
    }

    // MARK: loading

    /// Replaces the feed with `sources`. If every source fails, the feed keeps its
    /// previous content and sources (so a control can revert to what is shown),
    /// and the failures appear above it with a retry of the whole request.
    @discardableResult
    func reload(sources: [FeedSource], order: FeedOrder = .interleaved) async -> FeedReloadOutcome {
        generation &+= 1
        let current = generation
        isLoading = true
        var results: [(Int, Result<PluginPager<ContentItem>, Error>)] = []
        await withTaskGroup(of: (Int, Result<PluginPager<ContentItem>, Error>).self) { group in
            for (i, s) in sources.enumerated() { group.addTask { (i, await capture { try await s.open() }) } }
            for await r in group { results.append(r) }
        }
        guard current == generation else { return .superseded }
        results.sort { $0.0 < $1.0 }

        var opened: [Feeder] = []
        var newFailures: [(FeedSource, SourceFailure)] = []
        for (i, r) in results {
            switch r {
            case .success(let p): opened.append(Feeder(source: sources[i], pager: p))
            case .failure(let e):
                newFailures.append((sources[i], .record(pluginID: sources[i].runtime.id, sourceKey: sources[i].key,
                                                        label: sources[i].label, message: report(e, sources[i].runtime),
                                                        stage: .firstPage)))
            }
        }

        retryActions = [:]
        let outcome: FeedReloadOutcome
        if opened.isEmpty && !sources.isEmpty {
            // Keep showing the previous request; retrying repeats this whole one.
            failures = newFailures.map(\.1)
            for (_, failure) in newFailures {
                retryActions[failure.id] = { [weak self] in
                    guard let self else { return }
                    await self.reload(sources: sources, order: order)
                }
            }
            outcome = .failed
        } else {
            self.sources = sources
            self.order = order
            feeders = opened
            items = []
            seen = []
            failures = newFailures.map(\.1)
            for (source, failure) in newFailures {
                retryActions[failure.id] = { [weak self] in await self?.reopen(source) }
            }
            place(opened.map { ($0, $0.pager.initial) })
            didUpdate?(items)
            outcome = .refreshed
        }
        updateHasMore()
        isLoading = false
        loadedOnce = true
        if outcome == .refreshed && items.isEmpty && hasMore && order == .newestFirst {
            await loadMore()
            if current != generation { return .superseded }
        }
        return outcome
    }

    func loadMore() async {
        // A newest-first page can place nothing (a source answered with an empty
        // page but more to come); keep going a few rounds so the list never sits
        // empty with no last row to trigger the next load.
        for _ in 0..<5 {
            guard !isLoading, hasMore else { return }
            let before = items.count
            guard await fetchDuePages() else { return }
            if items.count > before || order == .interleaved { return }
        }
    }

    /// Fetches the next page of every source that is due; false if a reload superseded it.
    private func fetchDuePages() async -> Bool {
        let current = generation
        isLoading = true
        // Newest-first merging only needs the sources whose held-back items ran out.
        let due = feeders.filter { $0.hasMore && !$0.stalled && (order == .interleaved || $0.buffer.isEmpty) }
        var results: [(Int, Result<[ContentItem], Error>)] = []
        await withTaskGroup(of: (Int, Result<[ContentItem], Error>).self) { group in
            for (i, feeder) in due.enumerated() {
                let pager = feeder.pager
                group.addTask { (i, await capture { try await pager.next() }) }
            }
            for await r in group { results.append(r) }
        }
        guard current == generation else { return false }
        results.sort { $0.0 < $1.0 }
        var pages: [(Feeder, [ContentItem])] = []
        for (i, r) in results {
            let feeder = due[i]
            switch r {
            case .success(let page):
                clearFailure("\(feeder.source.key)|\(SourceFailure.Stage.nextPage.rawValue)")
                pages.append((feeder, page))
            case .failure(let e):
                stall(feeder, error: e)
            }
        }
        place(pages)
        didUpdate?(items)
        updateHasMore()
        isLoading = false
        return true
    }

    /// Retries one failed source. The row stays pending until the retry finishes.
    func retry(_ failure: SourceFailure) async {
        guard !retrying.contains(failure.id) else { return }
        retrying.insert(failure.id)
        defer { retrying.remove(failure.id) }
        if let action = retryActions[failure.id] {
            await action()
            return
        }
        if failure.stage == .nextPage, let feeder = feeders.first(where: { $0.source.key == failure.sourceKey }) {
            let current = generation
            let pager = feeder.pager
            switch await capture({ try await pager.next() }) {
            case .success(let page):
                guard current == generation else { return }
                feeder.stalled = false
                clearFailure(failure.id)
                place([(feeder, page)])
                didUpdate?(items)
            case .failure(let e):
                guard current == generation else { return }
                stall(feeder, error: e)
            }
            updateHasMore()
        }
    }

    /// Shows a failure that happened beside the feed (a search's channel results)
    /// in the feed's failure list, with the caller's retry.
    func record(_ failure: SourceFailure, retry: @escaping @MainActor () async -> SourceFailure?) {
        let current = generation
        replaceFailure(failure)
        retryActions[failure.id] = { [weak self] in
            let again = await retry()
            guard let self, current == self.generation else { return }
            if let again { self.replaceFailure(again) } else { self.clearFailure(failure.id) }
        }
    }

    // MARK: internals

    private func reopen(_ source: FeedSource) async {
        let current = generation
        let failureID = "\(source.key)|\(SourceFailure.Stage.firstPage.rawValue)"
        switch await capture({ try await source.open() }) {
        case .success(let pager):
            guard current == generation else { return }
            let feeder = Feeder(source: source, pager: pager)
            feeders.append(feeder)
            clearFailure(failureID)
            place([(feeder, pager.initial)])
            didUpdate?(items)
        case .failure(let e):
            guard current == generation else { return }
            replaceFailure(.record(pluginID: source.runtime.id, sourceKey: source.key, label: source.label,
                                   message: report(e, source.runtime), stage: .firstPage))
        }
        updateHasMore()
    }

    private func stall(_ feeder: Feeder, error: Error) {
        feeder.stalled = true
        replaceFailure(.record(pluginID: feeder.source.runtime.id, sourceKey: feeder.source.key,
                               label: feeder.source.label, message: report(error, feeder.source.runtime),
                               stage: .nextPage))
        // A stalled source no longer holds back the others.
        if order == .newestFirst { place([]) }
    }

    private func replaceFailure(_ failure: SourceFailure) {
        if let i = failures.firstIndex(where: { $0.id == failure.id }) { failures[i] = failure }
        else { failures.append(failure) }
    }

    private func clearFailure(_ id: String) {
        failures.removeAll { $0.id == id }
        retryActions[id] = nil
    }

    private func updateHasMore() {
        hasMore = feeders.contains { ($0.hasMore && !$0.stalled) || !$0.buffer.isEmpty }
    }

    private func place(_ pages: [(Feeder, [ContentItem])]) {
        switch order {
        case .interleaved:
            var out: [ContentItem] = []
            var i = 0
            while pages.contains(where: { i < $0.1.count }) {
                for page in pages where i < page.1.count { out.append(page.1[i]) }
                i += 1
            }
            for item in out where isNew(item) { items.append(item) }
        case .newestFirst:
            for (feeder, page) in pages { feeder.buffer.append(contentsOf: page.filter { !$0.url.isEmpty }) }
            mergeNewestFirst()
        }
    }

    private func isNew(_ item: ContentItem) -> Bool {
        !item.url.isEmpty && seen.insert(item.id).inserted
    }

    /// Moves held-back items into the timeline while every source that can still
    /// produce something newer has items buffered to compare against.
    private func mergeNewestFirst() {
        while true {
            let waiting = feeders.contains { $0.buffer.isEmpty && $0.hasMore && !$0.stalled }
            if waiting { return }
            guard let next = feeders.filter({ !$0.buffer.isEmpty })
                .max(by: { Self.isOlder($0.buffer[0], than: $1.buffer[0]) }) else { return }
            let item = next.buffer.removeFirst()
            if isNew(item) { insertNewestFirst(item) }
        }
    }

    /// Items come out of the merge in order; one from a source that was retried
    /// late still lands in its place.
    private func insertNewestFirst(_ item: ContentItem) {
        let index = items.lastIndex(where: { !Self.isOlder($0, than: item) }).map { $0 + 1 } ?? 0
        items.insert(item, at: index)
    }

    /// Undated items sort after dated ones.
    private static func isOlder(_ a: ContentItem, than b: ContentItem) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?): return x < y
        case (nil, _?): return true
        default: return false
        }
    }
}

// MARK: - Views

/// The failed sources of a feed, shown above its results.
@MainActor
private struct FeedFailures: View {
    let feed: FeedModel
    let inList: Bool

    var body: some View {
        if !feed.failures.isEmpty {
            if inList {
                Section("Some sources failed") { rows }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Some sources failed").font(.headline)
                    rows
                }
            }
        }
    }

    private var rows: some View {
        ForEach(feed.failures) { failure in
            SourceFailureRow(failure: failure, isRetrying: feed.retrying.contains(failure.id)) {
                Task { await feed.retry(failure) }
            }
        }
    }
}

@MainActor
struct FeedEmptyState: View {
    var title = "Nothing here yet"
    var message = "Pull down to refresh."

    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message))
    }
}

/// A feed as a list: `leading` rows (a search's channels, a playlist's header),
/// then the failed sources, then the items.
@MainActor
struct FeedList<Leading: View, Empty: View>: View {
    let feed: FeedModel
    var itemsHeader: String?
    /// Whether `leading` currently shows nothing, so the empty state may appear.
    var leadingIsEmpty: Bool
    let leading: Leading
    let empty: Empty

    init(feed: FeedModel, itemsHeader: String? = nil, leadingIsEmpty: Bool = true,
         @ViewBuilder leading: () -> Leading, @ViewBuilder empty: () -> Empty) {
        self.feed = feed
        self.itemsHeader = itemsHeader
        self.leadingIsEmpty = leadingIsEmpty
        self.leading = leading()
        self.empty = empty()
    }

    var body: some View {
        List {
            leading
            FeedFailures(feed: feed, inList: true)
            if let itemsHeader {
                Section(itemsHeader) { rows }
            } else {
                rows
            }
        }
        .listStyle(.plain)
        .overlay {
            if feed.loadedOnce && feed.items.isEmpty && feed.failures.isEmpty && leadingIsEmpty && !feed.isLoading {
                empty
            }
        }
    }

    private var rows: some View {
        Group {
            ForEach(feed.items) { item in
                ContentRow(item: item)
                    .hiddenListRowSeparator()
                    .loadsNextPageWhenLast(item.id == feed.items.last?.id) { await feed.loadMore() }
            }
            if feed.isLoading { ProgressView().frame(maxWidth: .infinity).hiddenListRowSeparator() }
            LoadMoreButton(feed: feed)
        }
    }
}

extension FeedList where Leading == EmptyView, Empty == FeedEmptyState {
    init(feed: FeedModel, emptyTitle: String = "Nothing here yet", emptyMessage: String = "Pull down to refresh.") {
        self.init(feed: feed, leading: { EmptyView() }, empty: { FeedEmptyState(title: emptyTitle, message: emptyMessage) })
    }
}

extension FeedList where Empty == FeedEmptyState {
    init(feed: FeedModel, leadingIsEmpty: Bool, @ViewBuilder leading: () -> Leading) {
        self.init(feed: feed, leadingIsEmpty: leadingIsEmpty, leading: leading, empty: { FeedEmptyState() })
    }
}

/// A feed as a grid inside a scrolling page (a channel): failed sources first.
@MainActor
struct FeedGrid: View {
    let feed: FeedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeedFailures(feed: feed, inList: false)
            ContentPreviewGrid(items: feed.items) { _ in
                await feed.loadMore()
            }
            if feed.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
            LoadMoreButton(feed: feed)
        }
    }
}
