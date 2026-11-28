import Foundation
import XCTest
@testable import HummingbirdKit

/// The playback queue belongs to the browser tab: each tab has its own, it is
/// saved with the tab, a new tab starts empty, closing a tab drops its queue,
/// and the queue the profile had before is given to the active tab once.
@MainActor
final class TabPlaybackQueueTests: XCTestCase {
    private func video(_ name: String) throws -> SavedVideo {
        SavedVideo(try JSONDecoder().decode(ContentItem.self, from: Data(
            #"{"contentType":1,"id":{"pluginId":"test","value":"\#(name)"},"name":"\#(name)","url":"https://test/\#(name)"}"#.utf8
        )))
    }

    private func app(_ stores: AppDataStores, profile: UUID, persistence: AppPersistenceSnapshot = .empty) -> AppModel {
        AppModel(persistence: persistence, stores: stores, localProfileID: profile, localNetworkSyncEnabled: false,
                 permissions: PermissionGate(system: PlatformPermissions(), ledger: InMemoryPermissionLedger()))
    }

    /// Relaunch: what the app loads at start, from what the last run saved.
    private func relaunch(_ stores: AppDataStores, profile: UUID) async -> AppModel {
        await stores.storage.flush()
        let snapshot = await AppPersistenceSnapshot.load(stores: stores, profileID: profile)
        return app(stores, profile: profile, persistence: snapshot ?? .empty)
    }

    func testEachTabHasItsOwnQueueAndItSurvivesARelaunch() async throws {
        let stores = makeTestStores()
        let profile = UUID()
        let first = app(stores, profile: profile)
        let tabA = first.activeTabID
        let queueA = first.queue(forTab: tabA)
        queueA.enqueue(try video("one"))
        queueA.playNext(try video("two"))
        queueA.cycleRepeatMode()

        first.openInNewTab(.home, title: "Home")
        let tabB = first.activeTabID
        XCTAssertNotEqual(tabA, tabB)
        XCTAssertTrue(first.queue(forTab: tabB).items.isEmpty, "a new tab starts with an empty queue")
        XCTAssertEqual(first.queue(forTab: tabA).items.map(\.name), ["two", "one"], "tab A keeps its own queue")
        first.queue(forTab: tabB).enqueue(try video("three"))

        let second = await relaunch(stores, profile: profile)
        XCTAssertEqual(second.queue(forTab: tabA).items.map(\.name), ["two", "one"], "A's queue is intact after a relaunch")
        XCTAssertEqual(second.queue(forTab: tabA).repeatMode, .all)
        XCTAssertEqual(second.queue(forTab: tabB).items.map(\.name), ["three"], "and B's is its own")
    }

    func testClosingATabDropsItsQueue() async throws {
        let stores = makeTestStores()
        let profile = UUID()
        let model = app(stores, profile: profile)
        model.openInNewTab(.home, title: "Home")
        let closing = model.activeTabID
        model.queue(forTab: closing).enqueue(try video("gone"))
        model.closeTab(closing)
        XCTAssertNil(model.tabQueues[closing], "the closed tab's queue went with it")

        let relaunched = await relaunch(stores, profile: profile)
        for tab in relaunched.contentTabs {
            XCTAssertTrue(relaunched.queue(forTab: tab.id).items.isEmpty)
        }
    }

    /// The queue the profile kept before tabs had their own: given to the
    /// active tab on the first launch after the change, then deleted.
    func testTheProfileQueueMovesToTheActiveTabOnce() async throws {
        let stores = makeTestStores()
        let profile = UUID()
        let old = PersistedPlaybackQueue(items: [try video("kept")], currentID: nil, repeatMode: .one, nextIndexHint: nil)
        let legacyName = "profile.\(profile.uuidString.lowercased()).playback_queue"
        stores.storage.save(old, name: legacyName)

        let migrated = await relaunch(stores, profile: profile)
        let active = migrated.activeTabID
        XCTAssertEqual(migrated.queue(forTab: active).items.map(\.name), ["kept"])
        XCTAssertEqual(migrated.queue(forTab: active).repeatMode, .one)
        await stores.storage.flush()
        XCTAssertNil(stores.storage.load(PersistedPlaybackQueue.self, name: legacyName), "the old store is gone")

        migrated.openInNewTab(.home, title: "Home")
        let again = await relaunch(stores, profile: profile)
        XCTAssertEqual(again.queue(forTab: active).items.map(\.name), ["kept"], "moved once, not copied")
        XCTAssertTrue(again.queue(forTab: again.contentTabs.last!.id).items.isEmpty)
    }
}
