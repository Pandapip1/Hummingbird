import ATProtoKit
import ATAppSync
import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// Two isolated Hummingbird profiles syncing over loopback LAN, as a Mac and
/// an iPhone do. Everything lives in per-test temporary directories with
/// in-memory credential stores and storage; plugin downloads are served by
/// `FakePluginHost`, never the network.
@MainActor
final class ProfileSyncApplyTests: XCTestCase {

    // MARK: end to end

    /// The reported bug: some plugins and all history never reached the
    /// other device. A plugin whose install fails used to abort the apply
    /// loop after everything had been marked merged, so every later record
    /// (other plugins, history, ...) was lost for good.
    func testEveryRecordReachesThePeerAndFailedInstallsAreRetried() async throws {
        let host = FakePluginHost()
        let alpha = host.serve(id: "alpha", name: "Alpha")
        let broken = host.serve(id: "broken", name: "Broken")
        // Twitch-like: Grayjay's Twitch config (Http package, signed) installs
        // fine on its own; on the phone it failed transiently, which used to
        // take every record after it down too.
        let twitch = host.serve(id: "6d1e5a47-3f0b-4c2e-9a51-7b0c2d9e8f13", name: "Twitch")  // not the reviewed Twitch: that id with another key is a lookalike
        let zulu = host.serve(id: "zulu", name: "Zulu")

        // Mac: plugins and library that existed before sync was active, and a
        // journal that already holds something, which used to skip bootstrap.
        let mac = try await SyncDevice.make(self, name: "mac", host: host, plugins: [
            try host.installed(alpha), try host.installed(broken),
            try host.installed(twitch, settings: ["shouldIncludeChannelClips": "false"]),
            try host.installed(zulu, enabled: false),
        ], history: [HistoryEntry(video: video(1), position: 10, date: Date(timeIntervalSince1970: 1_000))])
        try mac.mutationLog.appendPut(
            collection: HummingbirdProfileSchema.subscription,
            key: HummingbirdProfileSchema.key(for: "https://example.com/c/existing"),
            value: try ProfileEntity.subscription(Subscription(
                channelURL: "https://example.com/c/existing", pluginId: "alpha", name: "Existing"
            )).json()
        )
        mac.sync.bootstrapCurrentProfile()
        await mac.changes.flush()
        XCTAssertNil(mac.changes.lastError)
        // Subscription + one history entry + four plugins.
        XCTAssertEqual(mac.mutationLog.events().count, 6)
        // Progress recorded after activation, including updates to one entry.
        try mac.library.recordProgress(video(2), seconds: 5)
        try mac.library.recordProgress(video(2), seconds: 50)
        try mac.library.recordProgress(video(3), seconds: 7)
        mac.library.flushHistory()
        try mac.library.createPlaylist(name: "Later", videos: [video(4)])
        await mac.changes.flush()

        let phone = try await SyncDevice.make(self, name: "phone", host: host)
        try await SyncDevice.pair(mac, phone)

        host.failures = [broken.configURL: .max, twitch.configURL: 1]
        await phone.sync.sync()

        // Every library record arrived despite the failed installs.
        XCTAssertEqual(Set(phone.library.history.map(\.id)), Set(try [video(1), video(2), video(3)].map(\.id)))
        let second = try video(2)
        XCTAssertEqual(phone.library.history.first { $0.id == second.id }?.position, 50)
        XCTAssertEqual(phone.library.playlists.map(\.name), ["Later"])
        XCTAssertEqual(phone.library.subscriptions.map(\.name), ["Existing"])
        // Plugins after the failing ones in record order still installed.
        XCTAssertEqual(Set(phone.plugins.installed.map(\.id)), ["alpha", "zulu"])
        XCTAssertEqual(phone.plugins.plugin("zulu")?.enabled, false)
        // The failures are shown per plugin, not as a whole-sync failure.
        XCTAssertNotNil(phone.plugins.syncInstalls["broken"]?.failure)
        XCTAssertNotNil(phone.plugins.syncInstalls[twitch.id]?.failure)
        XCTAssertEqual(phone.sync.state, .idle)
        XCTAssertTrue(phone.sync.issues.contains { $0.contains("Twitch") })
        XCTAssertTrue(phone.sync.issues.contains { $0.contains("Broken") })

        // Next pass: nothing new arrives, but the failed records are retried.
        await phone.sync.sync()
        XCTAssertEqual(phone.plugins.plugin(twitch.id)?.settings, ["shouldIncludeChannelClips": "false"])
        XCTAssertNil(phone.plugins.syncInstalls[twitch.id])
        XCTAssertNotNil(phone.plugins.syncInstalls["broken"]?.failure)

        host.failures = [:]
        let fetchesBefore = host.fetchCount
        await phone.sync.sync()
        XCTAssertEqual(Set(phone.plugins.installed.map(\.id)), ["alpha", "broken", twitch.id, "zulu"])
        XCTAssertTrue(phone.plugins.syncInstalls.isEmpty)
        XCTAssertTrue(phone.sync.issues.isEmpty, "\(phone.sync.issues)")
        // Only the one missing plugin was downloaded (config and script).
        XCTAssertEqual(host.fetchCount - fetchesBefore, 2)
        XCTAssertTrue(phone.mutationLog.unappliedWinners().isEmpty)

        // And back: the phone's own edits reach the Mac.
        phone.plugins.setEnabled("alpha", false)
        try phone.library.recordProgress(video(5), seconds: 3)
        phone.library.flushHistory()
        await phone.changes.flush()
        await mac.sync.sync()
        XCTAssertEqual(mac.plugins.plugin("alpha")?.enabled, false)
        let fifth = try video(5)
        XCTAssertTrue(mac.library.history.contains { $0.id == fifth.id })
    }

    /// A plugin already installed from the same source takes the synced
    /// enabled state and settings; nothing is downloaded or reinstalled.
    func testInstalledPluginTakesSettingsWithoutDownloading() async throws {
        let host = FakePluginHost()
        let alpha = host.serve(id: "alpha", name: "Alpha")
        let mac = try await SyncDevice.make(self, name: "mac", host: host, plugins: [try host.installed(alpha)])
        let phone = try await SyncDevice.make(self, name: "phone", host: host, plugins: [try host.installed(alpha)])
        try await SyncDevice.pair(mac, phone)

        mac.plugins.setSetting(pluginID: "alpha", key: "region", value: "ca")
        await mac.changes.flush()
        let fetches = host.fetchCount
        await phone.sync.sync()

        XCTAssertEqual(phone.plugins.plugin("alpha")?.settings, ["region": "ca"])
        XCTAssertEqual(host.fetchCount, fetches)
    }

    /// Devices that already "lost" records: their journal knows events the
    /// library never got. The first pass with apply tracking reapplies
    /// everything the journal holds, with no peer involved.
    func testRecordsMergedButNeverAppliedAreRecovered() async throws {
        let host = FakePluginHost()
        let alpha = host.serve(id: "alpha", name: "Alpha")
        let source = try AppSyncMutationLog(fileURL: makeTestDirectory().appendingPathComponent("source.json"))
        try source.appendPut(collection: HummingbirdProfileSchema.history,
                             key: HummingbirdProfileSchema.key(for: video(1).id),
                             value: try ProfileEntity.history(HistoryEntry(video: video(1), position: 9, date: Date())).json())
        try source.appendPut(collection: HummingbirdProfileSchema.plugin,
                             key: HummingbirdProfileSchema.key(for: "alpha"),
                             value: try ProfileEntity.plugin(XCTUnwrap(SyncedPlugin(host.installed(alpha)))).json())

        let phone = try await SyncDevice.make(self, name: "phone", host: host)
        // What the old apply did before throwing: merged, never applied.
        try phone.mutationLog.merge(source.events(), needsUpload: true)
        XCTAssertEqual(phone.mutationLog.unappliedWinners().count, 2)

        await phone.sync.sync()
        XCTAssertEqual(phone.library.history.map(\.id), [try video(1).id])
        XCTAssertEqual(phone.plugins.installed.map(\.id), ["alpha"])
        XCTAssertTrue(phone.mutationLog.unappliedWinners().isEmpty)
    }

    // MARK: plugin installs

    /// Synced plugins install concurrently: N slow installs take about one
    /// install's time, not N times it.
    func testSyncedPluginsInstallInParallel() async throws {
        let host = FakePluginHost()
        host.delay = .milliseconds(400)
        let plugins = (0..<PluginManager.maximumConcurrentSyncInstalls).map {
            host.serve(id: "p\($0)", name: "Plugin \($0)")
        }
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: host.fetch)
        let changes = try plugins.map {
            PluginSyncChange(key: HummingbirdProfileSchema.key(for: $0.id),
                             plugin: try XCTUnwrap(SyncedPlugin(host.installed($0))))
        }

        let clock = ContinuousClock()
        let started = clock.now
        let applied = await manager.applySynced(changes)
        let elapsed = clock.now - started

        XCTAssertEqual(applied.count, plugins.count)
        XCTAssertEqual(manager.installed.count, plugins.count)
        // Each install is two 400 ms downloads; in series this is 4.8 s.
        XCTAssertLessThan(elapsed, .milliseconds(2_400), "installs ran serially: \(elapsed)")
        XCTAssertGreaterThanOrEqual(host.maximumConcurrentFetches, plugins.count)
    }

    /// While installs run, each shows as installing (no optimistic row).
    func testSyncInstallsShowPendingStateWhileInstalling() async throws {
        let host = FakePluginHost()
        host.delay = .milliseconds(300)
        let alpha = host.serve(id: "alpha", name: "Alpha")
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: host.fetch)
        let change = PluginSyncChange(key: HummingbirdProfileSchema.key(for: "alpha"),
                                      plugin: try XCTUnwrap(SyncedPlugin(host.installed(alpha))))
        let applying = Task { await manager.applySynced([change]) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.syncInstalls["alpha"], SyncInstall(pluginID: "alpha", sourceURL: alpha.configURL.absoluteString, failure: nil))
        XCTAssertTrue(manager.installed.isEmpty)
        _ = await applying.value
        XCTAssertNil(manager.syncInstalls["alpha"])
        XCTAssertEqual(manager.installed.map(\.id), ["alpha"])
    }

    // MARK: source-access policy

    /// A synced plugin this device's policy refuses is shown locked with the
    /// reason, not as a sync failure, is not recorded as applied, and
    /// installs by itself once the policy allows it.
    func testRefusedSyncedPluginIsLockedThenInstallsWhenAllowed() async throws {
        let host = FakePluginHost()
        let alpha = host.serve(id: "alpha", name: "Alpha")
        let stores = makeTestStores()
        let age = FixedAgeSource(.range(lowerBound: 13, upperBound: 15))
        let profileAge = ProfileAgeRange(storage: .inMemory(), storageName: "age", profileChanges: nil)
        let policy = SourceAccessPolicy(
            ageSource: age, supervisionSource: FixedSupervisionSource(.notSupervised), profileAge: profileAge,
            approvals: ParentalApprovals(storage: .inMemory(), storageName: "approvals", profileChanges: nil)
        )
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: policy, fetch: host.fetch)
        let change = PluginSyncChange(key: HummingbirdProfileSchema.key(for: "alpha"),
                                      plugin: try XCTUnwrap(SyncedPlugin(host.installed(alpha))))

        let applied = await manager.applySynced([change])
        XCTAssertTrue(applied.isEmpty, "a refused plugin is not recorded as applied")
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertEqual(manager.syncInstalls["alpha"]?.locked, .tooYoung(minimumAge: 18))
        XCTAssertNil(manager.syncInstalls["alpha"]?.failure, "locked, not an error")

        // A platform report of an adult raises the profile's bound; the
        // refused plugin is tried again and installs.
        age.answer = .range(lowerBound: 18, upperBound: nil)
        await manager.retryLockedSources()
        XCTAssertEqual(manager.installed.map(\.id), ["alpha"])
        XCTAssertNil(manager.syncInstalls["alpha"])
    }

    // MARK: library

    /// A sync result computed before a local edit is not committed over it.
    func testLocalEditDuringSyncIsNotOverwritten() async throws {
        let stores = makeTestStores()
        let library = LibraryStore(storage: stores.storage)
        let remote = Playlist(name: "Remote")
        let mutation = JournalMutation(
            collection: HummingbirdProfileSchema.playlist,
            recordKey: RecordKey(rawValue: remote.id.uuidString.lowercased())!,
            operation: .put, value: try ProfileEntity.playlist(remote).json(),
            timestamp: HybridLogicalTimestamp(milliseconds: 1, counter: 0, deviceID: UUID())
        )
        let batch = await LibrarySyncBatch.compute(
            from: library.syncBase(), changes: [LibrarySyncChange(mutation: mutation, entity: .playlist(remote))]
        )
        library.createPlaylist(name: "Local")
        XCTAssertTrue(library.commit(batch).isEmpty)
        XCTAssertEqual(library.playlists.map(\.name), ["Local"])

        let fresh = await LibrarySyncBatch.compute(
            from: library.syncBase(), changes: [LibrarySyncChange(mutation: mutation, entity: .playlist(remote))]
        )
        XCTAssertEqual(library.commit(fresh), [HummingbirdProfileSchema.playlist])
        XCTAssertEqual(Set(library.playlists.map(\.name)), ["Local", "Remote"])
    }

    /// Trimming history to the limit is local: it writes no deletions, which
    /// would remove those entries from every device. And a removal never
    /// takes away a watch that happened after it.
    func testHistoryLimitDoesNotDeleteAndRemovalsKeepNewerWatches() async throws {
        let log = try AppSyncMutationLog(fileURL: makeTestDirectory().appendingPathComponent("log.json"))
        let changes = ProfileChangeStore(mutationLog: log)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var snapshot = LibraryPersistenceSnapshot.empty
        snapshot.history = try (0..<LibraryStore.historyLimit).reversed().map {
            HistoryEntry(video: try video($0), position: 1, date: start.addingTimeInterval(Double($0)))
        }
        let library = LibraryStore(snapshot: snapshot, profileChanges: changes, storage: makeTestStores().storage)
        // One more than the limit: the oldest (video 0) is trimmed here only.
        try library.recordProgress(video(LibraryStore.historyLimit), seconds: 1,
                                   now: start.addingTimeInterval(Double(LibraryStore.historyLimit)))
        library.flushHistory()
        await changes.flush()
        XCTAssertEqual(library.history.count, LibraryStore.historyLimit)
        let first = try video(0)
        XCTAssertFalse(library.history.contains { $0.id == first.id })
        XCTAssertEqual(log.events().map(\.operation), [.put])

        let removedAt = HybridLogicalTimestamp(milliseconds: UInt64(start.timeIntervalSince1970 * 1_000) + 500_000,
                                               counter: 0, deviceID: UUID())
        let removals = try [video(10), video(LibraryStore.historyLimit)].map {
            LibrarySyncChange(mutation: JournalMutation(
                collection: HummingbirdProfileSchema.history, recordKey: HummingbirdProfileSchema.key(for: $0.id),
                operation: .delete, value: nil, timestamp: removedAt
            ), entity: nil)
        }
        let batch = await LibrarySyncBatch.compute(from: library.syncBase(), changes: removals)
        library.commit(batch)
        // Watched at +10 s, removed at +500 s: gone. Watched at +2000 s: kept.
        let early = try video(10), late = try video(LibraryStore.historyLimit)
        XCTAssertFalse(library.history.contains { $0.id == early.id })
        XCTAssertTrue(library.history.contains { $0.id == late.id })
    }

    /// Progress ticks update the library, but the journal (and so every
    /// peer snapshot) gets a record only every `historySyncInterval` and at
    /// flush points.
    func testProgressTicksAreCoalescedInTheJournal() async throws {
        let log = try AppSyncMutationLog(fileURL: makeTestDirectory().appendingPathComponent("log.json"))
        let changes = ProfileChangeStore(mutationLog: log)
        let writes = Counter()
        changes.setMutationHandler { writes.increment() }
        let library = LibraryStore(profileChanges: changes, storage: makeTestStores().storage)
        let start = Date()
        for tick in 0..<120 {   // ten minutes of 5-second ticks
            try library.recordProgress(video(1), seconds: Double(tick * 5), now: start.addingTimeInterval(Double(tick * 5)))
        }
        await changes.flush()
        XCTAssertEqual(writes.value, 10, "one write a minute")
        library.flushHistory()   // pause / stop
        await changes.flush()
        XCTAssertEqual(writes.value, 11)
        XCTAssertEqual(library.history.first?.position, 595)
        // Superseded events are dropped: one record, one event.
        XCTAssertEqual(log.events().count, 1)
        XCTAssertEqual(log.pending().count, 1)
    }

    // MARK: journal

    /// Merging is deterministic whatever order (and grouping) events arrive
    /// in: every journal ends with the same winners and the same events.
    func testMergeOutcomeIsIndependentOfArrivalOrder() throws {
        let directory = makeTestDirectory()
        let devices = try (0..<3).map {
            try AppSyncMutationLog(fileURL: directory.appendingPathComponent("device\($0).json"))
        }
        let collection = HummingbirdProfileSchema.history
        let keys = (0..<8).map { RecordKey(rawValue: "k\($0)")! }
        var generator = SeededGenerator(seed: 42)
        let base = Date(timeIntervalSince1970: 2_000_000)
        for step in 0..<60 {
            let device = devices[Int.random(in: 0..<devices.count, using: &generator)]
            let key = keys[Int.random(in: 0..<keys.count, using: &generator)]
            // Same millisecond on purpose now and then, to exercise tie-breaks.
            let now = base.addingTimeInterval(Double(step / 2))
            if Bool.random(using: &generator) {
                try device.appendPut(collection: collection, key: key, value: .string("v\(step)"), now: now)
            } else {
                try device.appendDelete(collection: collection, key: key, now: now)
            }
        }
        let all = devices.flatMap { $0.events() }

        var outcomes: [[String: JournalEventVersion]] = []
        var eventSets: [Set<UUID>] = []
        for trial in 0..<12 {
            let replica = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("replica\(trial).json"))
            var shuffled = all
            shuffled.shuffle(using: &generator)
            var remaining = shuffled[...]
            while !remaining.isEmpty {
                let size = Int.random(in: 1...max(1, remaining.count), using: &generator)
                try replica.merge(Array(remaining.prefix(size)), needsUpload: true)
                remaining = remaining.dropFirst(size)
            }
            var versions: [String: JournalEventVersion] = [:]
            for key in keys { versions[key.rawValue] = replica.version(collection: collection, key: key) }
            outcomes.append(versions)
            eventSets.append(Set(replica.events().map(\.id)))
            XCTAssertEqual(replica.events().count, Set(replica.events().map(\.recordKey)).count,
                           "one event per record")
        }
        XCTAssertTrue(outcomes.allSatisfy { $0 == outcomes[0] })
        XCTAssertTrue(eventSets.allSatisfy { $0 == eventSets[0] })
        XCTAssertFalse(outcomes[0].isEmpty)
    }

    /// A journal written by the previous version has no apply tracking (and
    /// keeps superseded events). Opening it marks nothing applied, so the
    /// first pass after the upgrade reapplies every record once; this is
    /// what brings back what the old apply lost. Superseded events go.
    func testLegacyJournalReappliesEverythingOnceAfterUpgrade() throws {
        let file = makeTestDirectory().appendingPathComponent("legacy.json")
        let log = try AppSyncMutationLog(fileURL: file)
        let collection = HummingbirdProfileSchema.history
        try log.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("1"))
        try log.appendPut(collection: collection, key: RecordKey(rawValue: "b")!, value: .string("1"))
        let latest = try log.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("2"))
        XCTAssertTrue(log.unappliedWinners().isEmpty)

        // Rewrite the file as the old version wrote it: no applied, arrivals
        // or epoch, and every event ever appended still listed.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["applied", "arrivals", "lastArrival", "epoch"] { object[key] = nil }
        var events = try XCTUnwrap(object["events"] as? [Any])
        let superseded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JournalMutation(
            collection: collection, recordKey: RecordKey(rawValue: "a")!, operation: .put, value: .string("0"),
            timestamp: HybridLogicalTimestamp(milliseconds: 1, counter: 0, deviceID: UUID())
        )))
        events.insert(superseded, at: 0)
        object["events"] = events
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let upgraded = try AppSyncMutationLog(fileURL: file)
        XCTAssertEqual(upgraded.events().count, 2)
        let unapplied = upgraded.unappliedWinners()
        XCTAssertEqual(Set(unapplied.map(\.recordKey.rawValue)), ["a", "b"])
        XCTAssertTrue(unapplied.contains(latest))
        try upgraded.markApplied(unapplied)
        XCTAssertTrue(try AppSyncMutationLog(fileURL: file).unappliedWinners().isEmpty)
    }

    /// A reader that says where it got up to gets only what arrived since;
    /// a cursor from another journal gets everything.
    func testIncrementalEventsSinceCursor() throws {
        let log = try AppSyncMutationLog(fileURL: makeTestDirectory().appendingPathComponent("log.json"))
        let collection = HummingbirdProfileSchema.history
        try log.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("1"))
        try log.appendPut(collection: collection, key: RecordKey(rawValue: "b")!, value: .string("1"))
        let first = log.events(after: nil)
        XCTAssertEqual(first.events.count, 2)

        let updated = try log.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("2"))
        let second = log.events(after: first.cursor)
        XCTAssertEqual(second.events, [updated])
        XCTAssertTrue(log.events(after: second.cursor).events.isEmpty)
        let foreign = JournalCursor(epoch: UUID(), arrival: second.cursor.arrival)
        XCTAssertEqual(log.events(after: foreign).events.count, 2)
    }

    /// History is capped in the journal the same way on every device: the
    /// newest records by version stay, older ones go without tombstones, and
    /// a peer that still has a dropped record can't bring it back.
    func testHistoryRetentionIsDeterministicAndDroppedRecordsStayDropped() throws {
        let directory = makeTestDirectory()
        let collection = HummingbirdProfileSchema.history
        let source = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("source.json"))
        let base = Date(timeIntervalSince1970: 3_000_000)
        let events = try (0..<6).map {
            try source.appendPut(collection: collection, key: RecordKey(rawValue: "h\($0)")!,
                                 value: .string("\($0)"), now: base.addingTimeInterval(Double($0)))
        }
        var generator = SeededGenerator(seed: 7)
        var kept: [Set<String>] = []
        for trial in 0..<5 {
            let replica = try AppSyncMutationLog(
                fileURL: directory.appendingPathComponent("replica\(trial).json"), retention: [collection: JournalRetention(limit: 3) { _ in nil }]
            )
            for event in events.shuffled(using: &generator) { try replica.merge([event], needsUpload: false) }
            // The full set again, as an old peer would send it.
            try replica.merge(events, needsUpload: false)
            let keys = Set(replica.events().map(\.recordKey.rawValue))
            XCTAssertEqual(keys, ["h3", "h4", "h5"])
            XCTAssertNil(replica.version(collection: collection, key: RecordKey(rawValue: "h0")!))
            XCTAssertFalse(replica.events().contains { $0.operation == .delete })
            kept.append(keys)
        }
        XCTAssertTrue(kept.allSatisfy { $0 == kept[0] })
        // A new watch of a dropped video is newer than the floor and stays.
        let rewatch = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("replica0.json"),
                                             retention: [collection: JournalRetention(limit: 3) { _ in nil }])
        try rewatch.appendPut(collection: collection, key: RecordKey(rawValue: "h0")!, value: .string("again"))
        XCTAssertTrue(rewatch.events().contains { $0.recordKey.rawValue == "h0" })
    }

    /// History retention ranks records by when they were watched, on every
    /// device and in the library alike. Introducing a library's history to
    /// the journal never brings back what retention dropped, and devices
    /// with the same history end with the same records.
    func testDroppedHistoryStaysDroppedThroughBootstrapAndMatchesTheLibrary() async throws {
        let directory = makeTestDirectory()
        let retention = [HummingbirdProfileSchema.history: JournalRetention(limit: 3) {
            HummingbirdProfileSchema.historyRank($0.value)
        }]
        let start = Date(timeIntervalSince1970: 4_000_000)
        let entries = try (0..<5).map {
            HistoryEntry(video: try video($0), position: 1, date: start.addingTimeInterval(Double($0)))
        }
        var snapshot = LibraryPersistenceSnapshot.empty
        snapshot.history = entries.reversed()

        func device(_ name: String) throws -> (AppSyncMutationLog, ProfileChangeStore, LibraryStore) {
            let log = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("\(name).json"),
                                             retention: retention)
            let changes = ProfileChangeStore(mutationLog: log)
            return (log, changes, LibraryStore(snapshot: snapshot, profileChanges: changes,
                                                storage: makeTestStores().storage))
        }
        let (macLog, macChanges, macLibrary) = try device("mac")
        let (phoneLog, phoneChanges, phoneLibrary) = try device("phone")

        for (changes, library) in [(macChanges, macLibrary), (phoneChanges, phoneLibrary)] {
            changes.bootstrap(library.history.map { .history($0) })
            await changes.flush()
        }
        let newest = Set(entries.suffix(3).map { HummingbirdProfileSchema.key(for: $0.id).rawValue })
        XCTAssertEqual(Set(macLog.events().map(\.recordKey.rawValue)), newest)

        // A second bootstrap (every launch does one) appends nothing.
        let before = macLog.events()
        macChanges.bootstrap(macLibrary.history.map { .history($0) })
        await macChanges.flush()
        XCTAssertEqual(macLog.events(), before)

        // Exchanging journals in both directions changes nothing either.
        try macLog.merge(phoneLog.events().shuffled(), needsUpload: true)
        try phoneLog.merge(macLog.events().shuffled(), needsUpload: true)
        XCTAssertEqual(Set(phoneLog.events().map(\.recordKey.rawValue)), newest)

        // Each library drops what its journal dropped, and they match.
        for (log, library) in [(macLog, macLibrary), (phoneLog, phoneLibrary)] {
            let floor = log.retentionFloor(for: HummingbirdProfileSchema.history)
            XCTAssertTrue(LibrarySyncBatch.needsTrim(library.history, to: floor))
            let batch = await LibrarySyncBatch.compute(from: library.syncBase(), changes: [], historyFloor: floor)
            library.commit(batch)
        }
        XCTAssertEqual(macLibrary.history.map(\.id), Array(entries.suffix(3).reversed().map(\.id)))
        XCTAssertEqual(phoneLibrary.history, macLibrary.history)
    }

    /// Keeping this device's copy is remembered: the same synced source is
    /// resolved without asking again or downloading, and nothing is published.
    func testKeepingLocalCopyIsRememberedAndNotRepublished() async throws {
        let host = FakePluginHost()
        let mine = host.serve(id: "alpha", name: "Alpha")
        let theirs = host.serve(id: "alpha", name: "Alpha Fork")
        let stores = makeTestStores()
        let log = try AppSyncMutationLog(fileURL: makeTestDirectory().appendingPathComponent("log.json"))
        let changes = ProfileChangeStore(mutationLog: log)
        let manager = PluginManager(installed: [try host.installed(mine)], profileChanges: changes,
                                    storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: host.fetch)
        let change = PluginSyncChange(key: HummingbirdProfileSchema.key(for: "alpha"),
                                      plugin: try XCTUnwrap(SyncedPlugin(host.installed(theirs))))
        _ = await manager.applySynced([change])
        XCTAssertNotNil(manager.syncInstalls["alpha"]?.confirmation)

        manager.keepLocalPlugin("alpha")
        await changes.flush()
        XCTAssertTrue(log.events().isEmpty, "keeping publishes nothing")
        let fetches = host.fetchCount
        let applied = await manager.applySynced([change])
        XCTAssertEqual(applied, [change.key])
        XCTAssertNil(manager.syncInstalls["alpha"])
        XCTAssertEqual(host.fetchCount, fetches)
        XCTAssertEqual(manager.plugin("alpha")?.config.sourceUrl, mine.configURL.absoluteString)
    }

    /// Journals old enough to record versions as bare timestamps also get
    /// every record reapplied once.
    func testTimestampOnlyLegacyJournalIsReappliedToo() throws {
        let file = makeTestDirectory().appendingPathComponent("legacy.json")
        let log = try AppSyncMutationLog(fileURL: file)
        let collection = HummingbirdProfileSchema.history
        let event = try log.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("1"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["applied", "arrivals", "lastArrival", "epoch", "floors"] { object[key] = nil }
        let timestamp = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.timestamp))
        object["versions"] = ["\(collection.rawValue)/a": timestamp]
        object["tombstones"] = [String: Any]()
        try JSONSerialization.data(withJSONObject: object).write(to: file)

        let upgraded = try AppSyncMutationLog(fileURL: file)
        XCTAssertEqual(upgraded.version(collection: collection, key: RecordKey(rawValue: "a")!), event.version)
        XCTAssertEqual(upgraded.unappliedWinners(), [event])
    }

    /// A removal arriving for a plugin that never installed here clears its row.
    func testRemovalClearsFailedInstallRow() async throws {
        let host = FakePluginHost()
        let alpha = host.serve(id: "alpha", name: "Alpha")
        host.failures = [alpha.configURL: .max]
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: host.fetch)
        let key = HummingbirdProfileSchema.key(for: "alpha")
        let put = PluginSyncChange(key: key, plugin: try XCTUnwrap(SyncedPlugin(host.installed(alpha))))
        _ = await manager.applySynced([put])
        XCTAssertNotNil(manager.syncInstalls["alpha"]?.failure)

        let applied = await manager.applySynced([PluginSyncChange(key: key, plugin: nil)])
        XCTAssertEqual(applied, [key])
        XCTAssertNil(manager.syncInstalls["alpha"])
    }

    /// A synced copy from another source never silently replaces this
    /// device's plugin: it waits, with its warnings, for the user's choice.
    func testReplacementFromAnotherSourceNeedsConfirmation() async throws {
        let host = FakePluginHost()
        let mine = host.serve(id: "alpha", name: "Alpha")
        let theirs = host.serve(id: "alpha", name: "Alpha Fork")
        let stores = makeTestStores()
        let manager = PluginManager(installed: [try host.installed(mine)], storage: stores.storage,
                                    credentialStore: stores.credentialStore, policy: makeTestPolicy(), fetch: host.fetch)
        let change = PluginSyncChange(key: HummingbirdProfileSchema.key(for: "alpha"),
                                      plugin: try XCTUnwrap(SyncedPlugin(host.installed(theirs, settings: ["a": "b"]))))

        let applied = await manager.applySynced([change])
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(manager.plugin("alpha")?.config.sourceUrl, mine.configURL.absoluteString)
        XCTAssertEqual(manager.syncInstalls["alpha"]?.confirmation?.replacing, mine.configURL.absoluteString)

        // Asked again on the next pass without downloading again.
        let fetches = host.fetchCount
        _ = await manager.applySynced([change])
        XCTAssertEqual(host.fetchCount, fetches)

        manager.confirmSyncedReplacement("alpha")
        XCTAssertEqual(manager.plugin("alpha")?.config.sourceUrl, theirs.configURL.absoluteString)
        XCTAssertEqual(manager.plugin("alpha")?.settings, ["a": "b"])
        XCTAssertNil(manager.syncInstalls["alpha"])
        let afterConfirming = await manager.applySynced([change])
        XCTAssertEqual(afterConfirming, [change.key])
    }

    /// Feed refreshes and progress ticks during a sync don't stop it from
    /// committing, and they aren't lost by the commit.
    func testBookkeepingDuringSyncNeitherBlocksNorIsLost() async throws {
        let stores = makeTestStores()
        let library = LibraryStore(storage: stores.storage)
        library.subscribe(url: "https://example.com/c/1", pluginId: "alpha", name: "One", thumbnail: nil)
        let remote = Playlist(name: "Remote")
        let playlistChange = LibrarySyncChange(mutation: JournalMutation(
            collection: HummingbirdProfileSchema.playlist,
            recordKey: RecordKey(rawValue: remote.id.uuidString.lowercased())!,
            operation: .put, value: try ProfileEntity.playlist(remote).json(),
            timestamp: HybridLogicalTimestamp(milliseconds: 1, counter: 0, deviceID: UUID())
        ), entity: .playlist(remote))
        let renamed = Subscription(channelURL: "https://example.com/c/1", pluginId: "alpha", name: "Renamed")
        let subscriptionChange = LibrarySyncChange(mutation: JournalMutation(
            collection: HummingbirdProfileSchema.subscription,
            recordKey: HummingbirdProfileSchema.key(for: renamed.channelURL),
            operation: .put, value: try ProfileEntity.subscription(renamed).json(),
            timestamp: HybridLogicalTimestamp(milliseconds: 2, counter: 0, deviceID: UUID())
        ), entity: .subscription(renamed))
        let historyEntry = HistoryEntry(video: try video(1), position: 5, date: Date(timeIntervalSince1970: 10))
        let historyChange = LibrarySyncChange(mutation: JournalMutation(
            collection: HummingbirdProfileSchema.history,
            recordKey: HummingbirdProfileSchema.key(for: historyEntry.id),
            operation: .put, value: try ProfileEntity.history(historyEntry).json(),
            timestamp: HybridLogicalTimestamp(milliseconds: 3, counter: 0, deviceID: UUID())
        ), entity: .history(historyEntry))

        let batch = await LibrarySyncBatch.compute(
            from: library.syncBase(), changes: [playlistChange, subscriptionChange, historyChange]
        )
        let fetched = Date(timeIntervalSince1970: 5_000)
        library.updateSubscription("https://example.com/c/1", fetched: fetched, newest: 42, cache: nil)
        try library.recordProgress(video(2), seconds: 30)

        XCTAssertEqual(library.commit(batch), [HummingbirdProfileSchema.playlist,
                                               HummingbirdProfileSchema.subscription,
                                               HummingbirdProfileSchema.history])
        XCTAssertEqual(library.subscriptions.first?.name, "Renamed")
        XCTAssertEqual(library.subscriptions.first?.lastFetched, fetched)
        XCTAssertEqual(library.subscriptions.first?.lastItemDate, 42)
        let second = try video(2)
        XCTAssertEqual(library.history.map(\.id), [second.id, historyEntry.id])
    }

    /// A sync asked for while a pass is finishing is not lost.
    func testSyncRequestedDuringAPassRunsAnotherPass() async throws {
        let device = try await SyncDevice.make(self, name: "solo", host: FakePluginHost())
        let first = Task { await device.sync.sync() }
        let second = Task { await device.sync.sync() }
        await first.value
        await second.value
        // A third call after both finished starts a fresh pass and returns.
        await device.sync.sync()
        XCTAssertEqual(device.sync.state, .idle)
    }

    // MARK: helpers

    private func video(_ n: Int) throws -> SavedVideo {
        let json = #"{"pluginId":"alpha","url":"https://example.com/v/\#(n)","name":"Video \#(n)","isLive":false,"contentType":1}"#
        return try JSONDecoder().decode(SavedVideo.self, from: Data(json.utf8))
    }
}

/// One isolated profile: its own temporary directories, in-memory stores,
/// instance identity, journal, LAN server, library, plugins and sync service.
@MainActor
private final class SyncDevice {
    let peerService: AppSyncPeerService
    let mutationLog: AppSyncMutationLog
    let changes: ProfileChangeStore
    let library: LibraryStore
    let plugins: PluginManager
    let sync: ProfileSyncService
    var advertisement: InstanceInboxAdvertisement?

    private init(peerService: AppSyncPeerService, mutationLog: AppSyncMutationLog, changes: ProfileChangeStore,
                 library: LibraryStore, plugins: PluginManager, sync: ProfileSyncService) {
        self.peerService = peerService
        self.mutationLog = mutationLog
        self.changes = changes
        self.library = library
        self.plugins = plugins
        self.sync = sync
    }

    static func make(_ test: XCTestCase, name: String, host: FakePluginHost,
                     plugins installed: [InstalledPlugin] = [], history: [HistoryEntry] = []) async throws -> SyncDevice {
        let stores = test.makeTestStores()
        let directory = test.makeTestDirectory("HummingbirdSync-\(name)")
        let peerService = try AppSyncPeerService(
            credentialStore: TestCredentialStore(), storageDirectory: directory.appendingPathComponent("appsync")
        )
        let mutationLog = try AppSyncMutationLog(
            fileURL: directory.appendingPathComponent("profile.json"), signer: peerService.peer.mutationSigner()
        )
        let changes = ProfileChangeStore(mutationLog: mutationLog)
        var snapshot = LibraryPersistenceSnapshot.empty
        snapshot.history = history
        let library = LibraryStore(snapshot: snapshot, profileChanges: changes, storage: stores.storage)
        let plugins = PluginManager(installed: installed, profileChanges: changes, storage: stores.storage,
                                    credentialStore: stores.credentialStore, policy: makeTestPolicy(), fetch: host.fetch)
        let sync = ProfileSyncService(changes: changes, mutationLog: mutationLog, library: library,
                                      plugins: plugins, peerService: peerService, localNetworkEnabled: true)
        let device = SyncDevice(peerService: peerService, mutationLog: mutationLog, changes: changes,
                                library: library, plugins: plugins, sync: sync)
        device.advertisement = try await peerService.startLANServer(appIDs: [HummingbirdProfileSchema.appID])
        test.addTeardownBlock { peerService.stopLANServer() }
        return device
    }

    /// Discovers and trusts each other, as emoji verification ends.
    static func pair(_ a: SyncDevice, _ b: SyncDevice) async throws {
        let appIDs: Set<AppSyncAppID> = [HummingbirdProfileSchema.appID]
        let aRegistration = try a.peerService.registration(appIDs: appIDs, advertisement: a.advertisement)
        let bRegistration = try b.peerService.registration(appIDs: appIDs, advertisement: b.advertisement)
        try a.peerService.observeDiscoveredRegistration(bRegistration)
        try b.peerService.observeDiscoveredRegistration(aRegistration)
        _ = try a.peerService.trust(b.peerService.peer.publicIdentity)
        _ = try b.peerService.trust(a.peerService.peer.publicIdentity)
    }
}

/// Serves plugin configs and scripts from memory, optionally slowly or
/// failing, and records how many downloads ran at once.
final class FakePluginHost: Sendable {
    struct Plugin: Sendable {
        let id: String
        let name: String
        let configURL: URL
        let config: Data
        let script: String
    }

    private struct State {
        var files: [URL: Data] = [:]
        var inFlight = 0
        var maximumConcurrentFetches = 0
        var fetchCount = 0
        /// Remaining failures per config URL (`.max`: always).
        var failures: [URL: Int] = [:]
        var delay: Duration = .zero
    }

    private let state = Mutex(State())

    var failures: [URL: Int] {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }
    var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }
    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var maximumConcurrentFetches: Int { state.withLock { $0.maximumConcurrentFetches } }

    func serve(id: String, name: String) -> Plugin {
        let folder = name.replacingOccurrences(of: " ", with: "")
        let base = URL(string: "https://plugins.example/\(folder)/")!
        let configURL = base.appendingPathComponent("\(folder)Config.json")
        let config = Data("""
        {"name":"\(name)","id":"\(id)","version":1,"scriptUrl":"./script.js","sourceUrl":"\(configURL.absoluteString)","packages":["Http"]}
        """.utf8)
        let script = """
        source.enable = function () {};
        source.getHome = function () { return new ContentPager([], false); };
        source.search = function () { return new ContentPager([], false); };
        source.isChannelUrl = function () { return false; };
        source.getChannel = function () { return null; };
        source.getChannelContents = function () { return new ContentPager([], false); };
        source.isContentDetailsUrl = function () { return false; };
        source.getContentDetails = function () { return null; };
        """
        state.withLock {
            $0.files[configURL] = config
            $0.files[base.appendingPathComponent("script.js")] = Data(script.utf8)
        }
        return Plugin(id: id, name: name, configURL: configURL, config: config, script: script)
    }

    func installed(_ plugin: Plugin, settings: [String: String] = [:], enabled: Bool = true) throws -> InstalledPlugin {
        InstalledPlugin(config: try JSONDecoder().decode(PluginConfig.self, from: plugin.config),
                        script: plugin.script, settings: settings, enabled: enabled)
    }

    var fetch: PluginFetch {
        { [self] request in try await respond(to: request) }
    }

    private func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let delay = state.withLock {
            $0.fetchCount += 1
            $0.inFlight += 1
            $0.maximumConcurrentFetches = max($0.maximumConcurrentFetches, $0.inFlight)
            return $0.delay
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        let data = state.withLock { state -> Data? in
            if let remaining = state.failures[url], remaining > 0 {
                if remaining != .max { state.failures[url] = remaining - 1 }
                return nil
            }
            return state.files[url]
        }
        guard let data else { throw URLError(.timedOut) }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Deterministic randomness, so a failing order can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
