import ATAppSync
import Foundation
import PlatformSupport
import Synchronization
import XCTest
@testable import HummingbirdKit

/// New-video notifications, decided on each device alone.
@MainActor
final class SubscriptionPollerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAVideoIsAnnouncedOnceAndAChannelsFirstCheckOnlyRecords() async throws {
        let setup = makeSetup(notify: true)
        setup.channel.items = [video("old", age: 3_600)]
        await poll(setup.poller, at: 4)               // first check: records only
        XCTAssertTrue(setup.notifier.posted.isEmpty)

        setup.channel.items = [video("new", age: 60), video("old", age: 3_600)]
        await poll(setup.poller, at: 30)
        XCTAssertEqual(setup.notifier.posted.map(\.body), ["Video new"])
        XCTAssertEqual(setup.notifier.posted.first?.title, "Channel")

        await poll(setup.poller, at: 60)               // same videos again
        XCTAssertEqual(setup.notifier.posted.count, 1, "never twice on one device")

        // Relaunched: what was announced is remembered.
        let relaunched = makePoller(setup, notifier: setup.notifier)
        await poll(relaunched, at: 90)
        XCTAssertEqual(setup.notifier.posted.count, 1)
    }

    func testNothingIsAnnouncedForAChannelThatDidNotAsk() async {
        let setup = makeSetup(notify: false)
        setup.channel.items = [video("old", age: 3_600)]
        await poll(setup.poller, at: 4)
        setup.channel.items = [video("new", age: 60)]
        await poll(setup.poller, at: 30)
        XCTAssertTrue(setup.notifier.posted.isEmpty)
        // Turned on later: what was already seen isn't announced then.
        setup.library.setNotifyOnNewVideos(true, channelURL: "https://example.com/c/1")
        await poll(setup.poller, at: 60)
        XCTAssertTrue(setup.notifier.posted.isEmpty)
    }

    func testNothingIsAnnouncedWithoutPermissionOrWhatTheProfileCannotOpen() async {
        let denied = makeSetup(notify: true, authorization: .denied)
        denied.channel.items = [video("old", age: 3_600)]
        await poll(denied.poller, at: 4)
        denied.channel.items = [video("new", age: 60)]
        await poll(denied.poller, at: 30)
        XCTAssertTrue(denied.notifier.posted.isEmpty)

        let blocked = makeSetup(notify: true, canOpen: false)
        blocked.channel.items = [video("old", age: 3_600)]
        await poll(blocked.poller, at: 4)
        blocked.channel.items = [video("new", age: 60)]
        await poll(blocked.poller, at: 30)
        XCTAssertTrue(blocked.notifier.posted.isEmpty)
    }

    func testAResultAnotherDeviceSharedIsUsedInsteadOfFetching() async throws {
        let cache = CacheJournal(directory: KeptDirectory(named: "SyncedCache", inDataDirectory: makeTestDirectory("SyncedCache")), profileID: UUID(),
                                 instance: AppSyncPeerID(signingKey: Data([1])), credentialStore: TestCredentialStore(),
                                 availability: UnprotectedDataAvailability())
        let first = makeSetup(notify: false, cache: cache)
        first.channel.items = [video("a", age: 60)]
        await poll(first.poller, at: 4)
        XCTAssertEqual(first.channel.fetches, 1)

        // Another profile window on this device (standing in for a peer):
        // the channel's result is in the cache, fresh, in the same context.
        let second = makeSetup(notify: false, cache: cache)
        await poll(second.poller, at: 4.01)
        XCTAssertEqual(second.channel.fetches, 0, "served from the synced cache")
        XCTAssertEqual(second.library.feedCache["https://example.com/c/1"]?.map(\.name), ["Video a"])
    }

    // MARK: helpers

    @MainActor
    private final class Channel {
        var items: [ContentItem] = []
        var fetches = 0
    }

    private final class RecordingNotifier: NewVideoNotifier {
        private let state: Mutex<(authorization: NotificationAuthorization, posted: [LocalNotification])>
        init(authorization: NotificationAuthorization) { state = Mutex((authorization, [])) }
        var posted: [LocalNotification] { state.withLock { $0.posted } }
        func authorization() async -> NotificationAuthorization { state.withLock { $0.authorization } }
        func post(_ notification: LocalNotification) async throws { state.withLock { $0.posted.append(notification) } }
    }

    private struct Setup {
        let library: LibraryStore
        let storage: Storage
        let channel: Channel
        let notifier: RecordingNotifier
        let poller: SubscriptionPoller
        let canOpen: Bool
        let cache: CacheJournal?
    }

    private func makeSetup(notify: Bool, authorization: NotificationAuthorization = .authorized,
                           canOpen: Bool = true, cache: CacheJournal? = nil) -> Setup {
        var snapshot = LibraryPersistenceSnapshot.empty
        var subscription = Subscription(channelURL: "https://example.com/c/1", pluginId: "alpha", name: "Channel")
        subscription.notifyOnNewVideos = notify
        snapshot.subscriptions = [subscription]
        let storage = makeTestStores().storage
        let library = LibraryStore(snapshot: snapshot, storage: storage)
        let channel = Channel()
        let notifier = RecordingNotifier(authorization: authorization)
        let poller = makePoller(library: library, storage: storage, channel: channel, notifier: notifier,
                                canOpen: canOpen, cache: cache)
        return Setup(library: library, storage: storage, channel: channel, notifier: notifier,
                     poller: poller, canOpen: canOpen, cache: cache)
    }

    private func makePoller(_ setup: Setup, notifier: RecordingNotifier) -> SubscriptionPoller {
        makePoller(library: setup.library, storage: setup.storage, channel: setup.channel, notifier: notifier,
                   canOpen: setup.canOpen, cache: setup.cache)
    }

    private func makePoller(library: LibraryStore, storage: Storage, channel: Channel, notifier: RecordingNotifier,
                            canOpen: Bool, cache: CacheJournal?) -> SubscriptionPoller {
        SubscriptionPoller(
            library: library, storage: storage, storagePrefix: "", notifier: notifier,
            canOpen: { _ in canOpen },
            fetch: { _ in channel.fetches += 1; return channel.items },
            cache: cache,
            context: { _ in CacheFetchContext(sourceVersion: "1", locale: "en-GB") }
        )
    }

    /// Polls `hours` after the start, with a generous window.
    private func poll(_ poller: SubscriptionPoller, at hours: Double) async {
        let now = start.addingTimeInterval(hours * 3_600)
        await poller.poll(budget: BackgroundBudget(duration: .seconds(30)), now: { now })
    }

    private func video(_ name: String, age: TimeInterval) -> ContentItem {
        let datetime = Int(start.timeIntervalSince1970 - age)
        let json = #"{"pluginId":"alpha","url":"https://example.com/v/\#(name)","name":"Video \#(name)","datetime":\#(datetime),"isLive":false,"contentType":1}"#
        return ContentItem(saved: try! JSONDecoder().decode(SavedVideo.self, from: Data(json.utf8)))
    }
}
