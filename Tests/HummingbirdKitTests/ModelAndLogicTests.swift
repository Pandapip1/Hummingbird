import XCTest
@testable import HummingbirdKit

final class ModelAndLogicTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @MainActor
    func testBrowserTabManagementCreatesSelectsAndClosesTabs() {
        let model = AppModel()
        model.openNewTab()
        let blank = model.activeTab
        XCTAssertNil(blank.current)

        model.openInNewTab(.content("first"), title: "First")
        let first = model.activeTab
        model.openInNewTab(.content("second"), title: "Second")
        let second = model.activeTab
        XCTAssertEqual(model.contentTabs.map(\.id), [blank.id, first.id, second.id])

        model.activeTabID = model.pinnedTab.id
        XCTAssertEqual(model.activeTab.id, model.pinnedTab.id)
        XCTAssertEqual(model.contentTabs.map(\.id), [blank.id, first.id, second.id],
                       "selecting Home must not close or replace content tabs")

        model.activeTabID = first.id
        model.closeTab(first.id)
        XCTAssertEqual(model.contentTabs.map(\.id), [blank.id, second.id])
        XCTAssertEqual(model.activeTabID, second.id)
        model.closeTab(second.id)
        model.closeTab(blank.id)
        XCTAssertEqual(model.activeTabID, model.pinnedTab.id)
    }

    @MainActor
    func testSearchHistoryDeduplicatesLimitsAndPersists() {
        var saved: [[String]] = []
        let history = SearchHistory(limit: 3, load: { ["Existing"] }, save: { saved.append($0) })
        history.record("  first  ")
        history.record("existing")
        history.record("second")
        history.record("third")

        XCTAssertEqual(history.queries, ["third", "second", "existing"])
        history.remove("second")
        XCTAssertEqual(history.queries, ["third", "existing"])
        history.clear()
        XCTAssertEqual(history.queries, [])
        XCTAssertEqual(saved.last, [])
    }

    func testStorageDatabasePersistsAndOverwritesValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HummingbirdStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage.sqlite3")

        do {
            let database = StorageDatabase(url: url)
            XCTAssertNil(database.load(name: "history"))
            XCTAssertTrue(database.save(Data("first".utf8), name: "history"))
            XCTAssertEqual(database.load(name: "history"), Data("first".utf8))
            XCTAssertTrue(database.save(Data("second".utf8), name: "history"))
        }

        let reopened = StorageDatabase(url: url)
        XCTAssertEqual(reopened.load(name: "history"), Data("second".utf8))
    }

    func testStorageBackendImportsLegacyJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HummingbirdStorageMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(["legacy", "value"]).write(to: legacyURL)

        let backend = StorageBackend(directory: directory)
        let imported: [String]? = backend.load([String].self, name: "history")
        XCTAssertEqual(imported, ["legacy", "value"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        let database = StorageDatabase(url: directory.appendingPathComponent("storage.sqlite3"))
        let stored = database.load(name: "history").flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        XCTAssertEqual(stored, imported)
    }

    func testStorageBackendReadsFallbackAfterDatabaseFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HummingbirdStorageFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory at the database path makes sqlite3_open_v2 fail without
        // making the surrounding storage directory unwritable.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("storage.sqlite3"),
            withIntermediateDirectories: false
        )

        let backend = StorageBackend(directory: directory)
        backend.save(["newest"], name: "history")
        let loaded: [String]? = backend.load([String].self, name: "history")
        XCTAssertEqual(loaded, ["newest"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path))
    }

    @MainActor
    func testPlaybackQueuePersistsOrderingAndRepeatState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HummingbirdQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = StorageBackend(directory: directory)
        func video(_ name: String) throws -> SavedVideo {
            SavedVideo(try decode(ContentItem.self,
                #"{"contentType":1,"id":{"pluginId":"test","value":"\#(name)"},"name":"\#(name)","url":"https://test/\#(name)"}"#))
        }
        let one = try video("one"), two = try video("two"), three = try video("three")

        let queue = PlaybackQueue(backend: backend)
        queue.beginPlaying(one)
        queue.enqueue(three)
        queue.playNext(two)
        XCTAssertEqual(queue.items.map(\.name), ["one", "two", "three"])
        XCTAssertEqual(queue.advanceAfterPlayback()?.name, "two")
        queue.moveDown(two)
        queue.cycleRepeatMode()

        let restored = PlaybackQueue(backend: backend)
        XCTAssertEqual(restored.items.map(\.name), ["one", "three", "two"])
        XCTAssertEqual(restored.current?.name, "two")
        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertEqual(restored.advanceAfterPlayback()?.name, "one")

        let removalQueue = PlaybackQueue(backend: backend, storageName: "removal_queue")
        removalQueue.beginPlaying(one)
        removalQueue.enqueue(two)
        removalQueue.enqueue(three)
        removalQueue.beginPlaying(two)
        removalQueue.remove(two)
        XCTAssertEqual(removalQueue.advanceAfterPlayback()?.name, "three")
        removalQueue.remove(three)
        XCTAssertNil(removalQueue.advanceAfterPlayback())

        let firstRemoval = PlaybackQueue(backend: backend, storageName: "first_removal_queue")
        firstRemoval.beginPlaying(one)
        firstRemoval.enqueue(two)
        firstRemoval.remove(one)
        XCTAssertEqual(firstRemoval.advanceAfterPlayback()?.name, "two")

        let multipleRemoval = PlaybackQueue(backend: backend, storageName: "multiple_removal_queue")
        multipleRemoval.beginPlaying(one)
        multipleRemoval.enqueue(two)
        multipleRemoval.enqueue(three)
        multipleRemoval.beginPlaying(two)
        multipleRemoval.remove(at: IndexSet([0, 1]))
        let restoredRemoval = PlaybackQueue(backend: backend, storageName: "multiple_removal_queue")
        XCTAssertEqual(restoredRemoval.advanceAfterPlayback()?.name, "three")

        let subsequentRemoval = PlaybackQueue(backend: backend, storageName: "subsequent_removal_queue")
        subsequentRemoval.beginPlaying(one)
        subsequentRemoval.enqueue(two)
        subsequentRemoval.enqueue(three)
        subsequentRemoval.beginPlaying(two)
        subsequentRemoval.remove(two)
        subsequentRemoval.remove(one)
        XCTAssertEqual(subsequentRemoval.advanceAfterPlayback()?.name, "three")
    }

    func testContentItemToleratesLooseTypes() throws {
        let item = try decode(ContentItem.self, """
        {"contentType":1,"plugin_type":"PlatformVideo","id":{"platform":"P","pluginId":"plug","value":"1"},
         "name":"Hello","url":"https://x/1","datetime":1700000000.0,"duration":"125","viewCount":12.0,
         "thumbnails":{"sources":[{"url":"https://x/a.jpg","quality":1},{"url":"https://x/b.jpg","quality":9}]},
         "author":{"id":{"platform":"P","pluginId":"plug","value":"c"},"name":"Chan","url":"https://x/c","thumbnail":null,"subscribers":"1500"},
         "isLive":false}
        """)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.duration, 125)
        XCTAssertEqual(item.viewCount, 12)
        XCTAssertEqual(item.author?.subscribers, 1500)
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://x/b.jpg")
        XCTAssertEqual(item.id, "plug|https://x/1")
    }

    func testLossyDecodingSkipsBadItems() throws {
        let payload = try decode(PagerPayload<ContentItem>.self, #"{"pager":1,"hasMore":true,"results":[{"name":"ok","url":"u"},"garbage",{"name":"ok2","url":"u2"}]}"#)
        XCTAssertEqual(payload.results.compactMap { $0.value }.count, 2)
    }

    func testVideoDetailsAndHandles() throws {
        let d = try decode(VideoDetails.self, """
        {"contentType":1,"name":"V","url":"https://x/v","id":{"pluginId":"p","value":"v"},"description":"d","__handle":7,
         "has_getComments":true,
         "video":{"isUnMuxed":true,
           "videoSources":[{"plugin_type":"VideoUrlSource","url":"https://x/v.mp4","height":720,"width":1280,"container":"video/mp4","requestModifier":{"handle":3,"allowByteSkip":false}}],
           "audioSources":[{"plugin_type":"AudioUrlSource","url":"https://x/a.m4a","container":"audio/mp4","bitrate":128000,"language":"en"}]},
         "subtitles":[{"name":"English","url":"https://x/s.vtt","format":"text/vtt"}]}
        """)
        XCTAssertEqual(d.handle, 7)
        XCTAssertTrue(d.hasComments)
        XCTAssertTrue(d.isUnmuxed)
        XCTAssertEqual(d.videoSources.first?.requestModifier?.handle, 3)
        XCTAssertEqual(d.videoSources.first?.requestModifier?.allowByteSkip, false)
        XCTAssertEqual(d.subtitles.count, 1)
    }

    func testPlaybackSelection() throws {
        let d = try decode(VideoDetails.self, """
        {"contentType":1,"name":"V","url":"u","id":{"pluginId":"p","value":"v"},"description":"",
         "video":{"isUnMuxed":true,
           "videoSources":[
             {"plugin_type":"VideoUrlSource","url":"https://x/1080.mp4","height":1080,"container":"video/mp4"},
             {"plugin_type":"VideoUrlSource","url":"https://x/720.mp4","height":720,"container":"video/mp4"},
             {"plugin_type":"VideoUrlSource","url":"https://x/4k.webm","height":2160,"container":"video/webm"}],
           "audioSources":[
             {"plugin_type":"AudioUrlSource","url":"https://x/lo.m4a","container":"audio/mp4","bitrate":64000,"language":"en"},
             {"plugin_type":"AudioUrlSource","url":"https://x/hi.m4a","container":"audio/mp4","bitrate":192000,"language":"en"},
             {"plugin_type":"AudioUrlSource","url":"https://x/op.webm","container":"audio/webm","bitrate":256000,"language":"en"}]}}
        """)
        let options = PlaybackSelector.options(for: d)
        XCTAssertEqual(options.count, 2, "WebM video must be dropped")
        XCTAssertTrue(options.allSatisfy { $0.audio?.url == "https://x/hi.m4a" }, "best playable audio is chosen")
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: true)?.height, 1080)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 720, preferAdaptive: true)?.height, 720)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 480, preferAdaptive: true)?.height, 720, "falls back to the smallest if all are too tall")
    }

    func testHLSPreferredWhenAdaptive() throws {
        let d = try decode(VideoDetails.self, """
        {"contentType":1,"name":"V","url":"u","id":{"pluginId":"p","value":"v"},"description":"",
         "video":{"isUnMuxed":false,"videoSources":[
            {"plugin_type":"VideoUrlSource","url":"https://x/720.mp4","height":720,"container":"video/mp4"},
            {"plugin_type":"HLSSource","url":"https://x/master.m3u8","name":"HLS"}]}}
        """)
        let options = PlaybackSelector.options(for: d)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: true)?.kind, .hls)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: false)?.kind, .progressive)
    }

    func testSubtitleParsing() {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.500\nHello <b>world</b>\n\n1\n00:01:02,000 --> 00:01:04,000 align:start\nSecond\nline\n"
        let cues = SubtitleParser.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello world")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].start, 62.0, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "Second\nline")
    }

    func testSubscriptionMergeOrdersAndDedupes() throws {
        let now = Int(Date().timeIntervalSince1970)
        func item(_ plugin: String, _ name: String, _ offset: Int) throws -> ContentItem {
            try decode(ContentItem.self, #"{"contentType":1,"id":{"pluginId":"\#(plugin)","value":"\#(name)"},"name":"\#(name)","url":"https://\#(plugin)/\#(name)","datetime":\#(now - offset)}"#)
        }
        let merged = SubscriptionFeed.merge([
            try item("a", "Old", 86_400 * 10),
            try item("a", "New", 60),
            try item("b", "New", 3_600),          // same title an hour apart on another plugin: duplicate
            try item("b", "Middle", 86_400 * 3),
        ])
        XCTAssertEqual(merged.map(\.name), ["New", "Middle", "Old"])
        XCTAssertEqual(merged.first?.platformID.pluginId, "a")
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.duration(65), "1:05")
        XCTAssertEqual(Fmt.duration(3_725), "1:02:05")
        XCTAssertEqual(Fmt.count(999), "999")
        XCTAssertEqual(Fmt.count(1_500), "1.5K")
        XCTAssertEqual(Fmt.count(2_500_000), "2.5M")
    }

    func testPluginErrorMapping() throws {
        func map(_ json: String) throws -> PluginError {
            PluginError(payload: try JSONDecoder().decode(PluginError.Payload.self, from: Data(json.utf8)))
        }
        guard case .loginRequired = try map(#"{"type":"ScriptLoginRequiredException","msg":"x"}"#) else { return XCTFail("login") }
        guard case .captchaRequired(let url, _) = try map(#"{"type":"CaptchaRequiredException","url":"https://c"}"#) else { return XCTFail("captcha") }
        XCTAssertEqual(url, "https://c")
        guard case .execution = try map(#"{"type":"WhoKnows","msg":"x"}"#) else { return XCTFail("fallback") }
    }
}
