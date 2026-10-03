import XCTest
@testable import HummingbirdKit

final class ModelAndLogicTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
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
