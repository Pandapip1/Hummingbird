import ATAppSync
import Foundation
import os
import PlatformSupport

/// Where new-video notifications go: the system's notification center in
/// the app (`SystemNewVideoNotifier`), a recorder in tests.
protocol NewVideoNotifier: Sendable {
    func authorization() async -> NotificationAuthorization
    func post(_ notification: LocalNotification) async throws
}

struct SystemNewVideoNotifier: NewVideoNotifier {
    func authorization() async -> NotificationAuthorization { await LocalNotifications.center.authorization() }
    func post(_ notification: LocalNotification) async throws { try await LocalNotifications.center.post(notification) }
}

/// Checks subscribed channels for new videos in background windows (and on
/// the desktop's timer), on this device alone:
///
/// - Each channel is checked on its own adaptive schedule, spread out,
///   within each plugin's rate limits (ATAppSync's `RefreshScheduler`).
/// - A channel a trusted device checked recently enough (its result is in
///   the synced cache, in this device's exact fetch context) isn't asked
///   again: one device's refresh serves the others.
/// - A video is announced at most once on this device, and only for a
///   channel whose "notify on new videos" is on, when the system allows
///   notifications and this profile may open the video. A channel's first
///   check only records what is already there. Every device does this
///   independently: there is no cross-device deduplication.
@MainActor
final class SubscriptionPoller {
    /// What a poll remembers, on this device only (never synced).
    struct State: Codable, Equatable {
        var scheduler = RefreshScheduler()
        /// Videos already announced or seen, newest last; bounded.
        var notified: [String] = []
        /// Channels checked at least once.
        var seeded: Set<String> = []

        static let notifiedLimit = 5_000

        mutating func remember(_ ids: [String]) {
            notified.append(contentsOf: ids)
            if notified.count > Self.notifiedLimit { notified.removeFirst(notified.count - Self.notifiedLimit) }
        }
    }

    private let library: LibraryStore
    private let storage: Storage
    private let storageName: String
    private let notifier: any NewVideoNotifier
    private let canOpen: @MainActor (SavedVideo) -> Bool
    private let fetch: @MainActor (Subscription) async throws -> [ContentItem]
    private let cache: CacheJournal?
    /// The fetch context for a plugin's results, or nil when they must not
    /// be shared (signed in: this device can't name the account safely).
    private let context: @MainActor (String) -> CacheFetchContext?
    private(set) var state: State
    private var authorization: NotificationAuthorization?

    init(library: LibraryStore, storage: Storage, storagePrefix: String, notifier: any NewVideoNotifier,
         canOpen: @escaping @MainActor (SavedVideo) -> Bool,
         fetch: @escaping @MainActor (Subscription) async throws -> [ContentItem],
         cache: CacheJournal?, context: @escaping @MainActor (String) -> CacheFetchContext?) {
        self.library = library
        self.storage = storage
        storageName = storagePrefix + "subscription_poll"
        self.notifier = notifier
        self.canOpen = canOpen
        self.fetch = fetch
        self.cache = cache
        self.context = context
        state = storage.load(State.self, name: storageName) ?? State()
    }

    /// Checks the channels that are due, within `budget`. What doesn't fit
    /// stays due for the next window.
    @discardableResult
    func poll(budget: BackgroundBudget, now: @escaping @Sendable () -> Date = { Date() }) async -> BackgroundRunReport<String> {
        authorization = nil
        state.scheduler.track(library.subscriptions.map { ($0.channelURL, $0.pluginId) }, now: now())
        let due = state.scheduler.due(now: now()).map(\.key)
        let report = await BackgroundRunner.run(due, budget: budget) { [weak self] key in
            try await self?.check(key, now: now)
        }
        storage.save(state, name: storageName)
        library.persistSubscriptionState()
        cache?.persist()
        Logger.background.notice("subscription_poll checked=\(report.completed.count) failed=\(report.failed.count) deferred=\(report.deferred.count)")
        return report
    }

    /// The plugin asked to be left alone for now (it failed, or said when
    /// to retry); its channels wait for their next window.
    struct SourceBackingOff: Error {}

    private func check(_ channelURL: String, now: @Sendable () -> Date) async throws {
        guard let subscription = library.subscriptions.first(where: { $0.channelURL == channelURL }),
              let item = state.scheduler.items[channelURL] else { return }
        let items: [ContentItem]
        if let shared = sharedResult(for: subscription, interval: item.interval, now: now()) {
            items = shared
        } else {
            guard let slot = state.scheduler.nextSlot(for: subscription.pluginId, now: now()) else {
                throw SourceBackingOff()
            }
            let wait = slot.timeIntervalSince(now())
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            state.scheduler.recordRequest(source: subscription.pluginId, at: now())
            do {
                items = try await fetch(subscription)
            } catch {
                state.scheduler.recordFailure(key: channelURL, now: now())
                throw error
            }
            share(items, for: subscription, fetchedAt: now())
        }
        let updates = items.compactMap(\.datetime).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        state.scheduler.recordSuccess(key: channelURL, updates: updates, now: now())
        library.updateSubscription(channelURL, fetched: now(), newest: items.compactMap(\.datetime).max(),
                                   cache: Array(items.prefix(30).map(SavedVideo.init)))
        await announce(items, for: subscription)
    }

    /// A trusted device's result for this channel, fetched in exactly this
    /// device's context and recently enough. Nil means fetch it here.
    private func sharedResult(for subscription: Subscription, interval: TimeInterval, now: Date) -> [ContentItem]? {
        guard let cache, let context = context(subscription.pluginId),
              let list = cache.list(listKey(subscription), for: CacheViewer(contexts: [subscription.pluginId: context]), now: now),
              list.fit == .fresh, !list.isPartial, now.timeIntervalSince(list.fetchedAt) < interval else { return nil }
        let decoder = JSONDecoder()
        return list.entities.compactMap { try? decoder.decode(SavedVideo.self, from: $0.payload) }.map { ContentItem(saved: $0) }
    }

    private func share(_ items: [ContentItem], for subscription: Subscription, fetchedAt: Date) {
        guard let cache, let context = context(subscription.pluginId) else { return }
        let encoder = JSONEncoder()
        let entities: [(key: CacheEntityKey, payload: Data, fields: [String: Data])] = items.prefix(30).compactMap { item in
            guard let payload = try? encoder.encode(SavedVideo(item)) else { return nil }
            return (CacheEntityKey(kind: "video", source: subscription.pluginId, url: item.url), payload, [:])
        }
        cache.put(listKey(subscription), context: context, entities: entities, fetchedAt: fetchedAt)
    }

    private func listKey(_ subscription: Subscription) -> CacheListKey {
        CacheListKey(kind: "channel-latest", source: subscription.pluginId, url: subscription.channelURL)
    }

    /// Announces what this device hasn't seen yet, once.
    private func announce(_ items: [ContentItem], for subscription: Subscription) async {
        let ids = items.map(\.id)
        guard state.seeded.contains(subscription.channelURL) else {
            // First check of this channel: what's there now isn't new.
            state.seeded.insert(subscription.channelURL)
            state.remember(ids)
            return
        }
        let known = Set(state.notified)
        let fresh = items.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        state.remember(fresh.map(\.id))
        guard subscription.notifyOnNewVideos == true else { return }
        if authorization == nil { authorization = await notifier.authorization() }
        guard authorization == .authorized else { return }
        for item in fresh where canOpen(SavedVideo(item)) {
            do {
                try await notifier.post(LocalNotification(
                    identifier: "new-video|" + item.id, title: subscription.name, body: item.name,
                    thread: subscription.channelURL
                ))
            } catch {
                Logger.background.error("new_video_notification_failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }
}
