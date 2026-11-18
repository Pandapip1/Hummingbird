import Foundation
import XCTest
@testable import HummingbirdKit

/// Plugin results are data, never code: hostile values a plugin returns are
/// bounded, stripped of unsafe URLs and spoofing text, and bound to the plugin
/// that produced them before the UI sees them. No network: the policy's
/// resolver is a fixed table.
final class PluginOutputContainmentTests: XCTestCase {
    private struct FakeResolver: HostResolving {
        func resolve(host: String, port: Int) throws -> [IPAddress] {
            if let literal = IPAddress(literal: host) { return [literal] }
            return [IPAddress(literal: "93.184.216.34")!]
        }
    }

    private func context(approvals: [LocalHostApproval] = []) throws -> PluginOutputContext {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data("""
            {"name":"Hostile","id":"hostile-plugin","allowUrls":["example.com",".allowed.test"]}
            """.utf8))
        return PluginOutputContext(
            pluginID: "hostile-plugin",
            policy: PluginNetworkPolicy(config: config, approvals: approvals, resolver: FakeResolver())
        )
    }

    private func decode<T: PluginOutput>(_ type: T.Type, _ json: Any, approvals: [LocalHostApproval] = []) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: json)
        var value = try JSONDecoder().decode(T.self, from: data)
        value.contain(try context(approvals: approvals))
        return value
    }

    func testOnlyPublicHTTPImageURLsSurvive() throws {
        let item = try decode(ContentItem.self, [
            "contentType": 1, "name": "x", "url": "https://example.com/v",
            "thumbnails": ["sources": [
                ["url": "javascript:alert(1)", "quality": 9],
                ["url": "file:///etc/passwd", "quality": 8],
                ["url": "data:image/png;base64,AAAA", "quality": 7],
                ["url": "http://127.0.0.1:8080/admin", "quality": 6],
                ["url": "http://192.168.1.1/cgi-bin/reboot", "quality": 6],
                ["url": "http://router.local/x.png", "quality": 6],
                ["url": "https://user:pw@cdn.public.test/t.jpg", "quality": 5],
                ["url": "hummingbird://settings", "quality": 5],
                ["url": "https://cdn.public.test/t.jpg", "quality": 1],
            ]],
            "thumbnail": "http://169.254.169.254/latest/meta-data/",
            "images": ["https://cdn.public.test/a.png", "ftp://cdn.public.test/b.png", "http://[::1]/c.png"],
        ])
        XCTAssertEqual(item.thumbnails.map(\.url), ["https://cdn.public.test/t.jpg"])
        XCTAssertNil(item.thumbnail)
        XCTAssertEqual(item.images, ["https://cdn.public.test/a.png"])
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://cdn.public.test/t.jpg")
    }

    func testApprovedLocalHostImagesSurvive() throws {
        let approval = LocalHostApproval(host: "nas.local", port: 80, networks: [IPNetwork(cidr: "192.168.1.20")!])
        let item = try decode(ContentItem.self, [
            "contentType": 1, "url": "x", "thumbnail": "http://nas.local/poster.jpg",
        ], approvals: [approval])
        XCTAssertEqual(item.thumbnail, "http://nas.local/poster.jpg")
    }

    func testExternalLinksMustBeAllowListedHTTP() throws {
        let locked = try decode(ContentItem.self, ["contentType": 70, "url": "x", "unlockUrl": "javascript:alert(document.cookie)"])
        XCTAssertNil(locked.unlockURL)
        let phishing = try decode(ContentItem.self, ["contentType": 70, "url": "x", "unlockUrl": "https://evil.test/login"])
        XCTAssertNil(phishing.unlockURL, "a host outside the plugin's allow-list is never opened")
        let scheme = try decode(ContentItem.self, ["contentType": 70, "url": "x", "unlockUrl": "tel:+15555550100"])
        XCTAssertNil(scheme.unlockURL)
        let allowed = try decode(ContentItem.self, ["contentType": 70, "url": "x", "unlockUrl": "https://shop.allowed.test/join"])
        XCTAssertEqual(allowed.unlockURL?.url.absoluteString, "https://shop.allowed.test/join")
        let share = try decode(ContentItem.self, ["contentType": 1, "url": "x", "shareUrl": "https://evil.test/s"])
        XCTAssertNil(share.shareUrl)

        let channel = try decode(ChannelInfo.self, [
            "name": "c", "url": "https://example.com/c",
            "links": [
                "Site": "https://example.com/about",
                "Evil": "https://evil.test/",
                "Script": "javascript:alert(1)",
                "Local": "http://192.168.0.1/",
                "Deep": "grayjay://plugin/https://evil.test/config.json",
            ],
        ])
        XCTAssertEqual(channel.links.mapValues(\.url.absoluteString), ["Site": "https://example.com/about"])
    }

    func testPluginCannotClaimAnotherPluginsIdentity() throws {
        let item = try decode(ContentItem.self, [
            "contentType": 1, "url": "https://example.com/v",
            "id": ["platform": "YouTube", "pluginId": "35ae969a-a7db-11ed-afa1-0242ac120002", "value": "v"],
            "author": ["id": ["pluginId": "35ae969a-a7db-11ed-afa1-0242ac120002", "value": "a"], "name": "Official", "url": "a"],
        ])
        XCTAssertEqual(item.platformID.pluginId, "hostile-plugin")
        XCTAssertEqual(item.author?.id.pluginId, "hostile-plugin")
        XCTAssertTrue(item.id.hasPrefix("hostile-plugin|"))

        let comment = try decode(PluginComment.self, [
            "author": ["id": ["pluginId": "someone-else"], "name": "n", "url": "u"], "message": "m",
        ])
        XCTAssertEqual(comment.author.id.pluginId, "hostile-plugin")
    }

    func testOversizedValuesAreBounded() throws {
        let huge = String(repeating: "A", count: 10 * 1024 * 1024)
        let item = try decode(ContentItem.self, [
            "contentType": 1, "url": huge, "name": huge, "description": huge,
            "thumbnails": (0..<100_000).map { ["url": "https://cdn.public.test/\($0).jpg", "quality": $0] },
            "images": (0..<100_000).map { "https://cdn.public.test/\($0).png" },
        ])
        XCTAssertLessThanOrEqual(item.name.count, PluginLimits.maximumTitleLength)
        XCTAssertLessThanOrEqual(item.url.count, PluginLimits.maximumURLLength)
        XCTAssertLessThanOrEqual(item.description?.count ?? 0, PluginLimits.maximumTextLength)
        XCTAssertLessThanOrEqual(item.thumbnails.count, 32)
        XCTAssertLessThanOrEqual(item.images.count, 64)

        let suggestions = try decode([PluginLine].self, (0..<100_000).map { "s\($0)" })
        let long = try decode([PluginLine].self, (0..<10).map { _ in String(repeating: "x", count: 1_000_000) })
        XCTAssertLessThanOrEqual(suggestions.count, PluginLimits.maximumListLength)
        XCTAssertTrue(long.allSatisfy { $0.text.count <= PluginLimits.maximumTitleLength })

        let capsJSON: [String: Any] = [
            "types": (0..<1_000).map { "T\($0)" },
            "filters": (0..<200).map { group -> [String: Any] in
                ["id": "g\(group)", "name": "G", "filters": (0..<500).map { ["id": "f\($0)", "name": "F", "value": "v"] }]
            },
        ]
        let caps = try decode(ResultCapabilities.self, capsJSON)
        XCTAssertLessThanOrEqual(caps.types.count, 20)
        XCTAssertLessThanOrEqual(caps.filters.count, 50)
        XCTAssertTrue(caps.filters.allSatisfy { $0.filters.count <= 100 })
    }

    func testSpoofingCharactersAreRemovedFromText() throws {
        // U+202E RIGHT-TO-LEFT OVERRIDE would render "Official\u{202E}gnp.exe" as "Officialexe.png".
        let item = try decode(ContentItem.self, [
            "contentType": 1, "url": "x",
            "name": "Official\u{202E}gnp.exe\u{2066}x\u{2069}\nSecond line\u{0007}",
            "author": ["name": "Hummingbird\u{2028}System", "url": "a"],
        ])
        XCTAssertEqual(item.name, "Officialgnp.exex Second line")
        XCTAssertEqual(item.author?.name, "Hummingbird System")
    }

    func testHTMLIsOnlyEverPlainText() {
        let html = """
            <p>Hello &amp; welcome</p><script>steal(document.cookie)</script><style>body{}</style>\
            <a href="javascript:alert(1)">link</a>&#x202E;evil&#7;&#65;&lt;b&gt;<img src=x onerror=alert(1)>tail<b
            """
        let text = PluginText.plain(html)
        XCTAssertFalse(text.contains("steal"))
        XCTAssertFalse(text.contains("body{}"))
        XCTAssertFalse(text.contains("<img"))
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertFalse(text.contains("\u{0007}"))
        XCTAssertTrue(text.contains("Hello & welcome"))
        XCTAssertTrue(text.contains("link"))
        XCTAssertTrue(text.contains("A<b>"), "escaped markup stays visible text, decoded once")
        XCTAssertTrue(text.hasSuffix("tail"), "an unterminated tag is dropped")
        XCTAssertEqual(PluginText.decodeEntities("&amp;lt;"), "&lt;")
    }

    func testMediaSourceURLsAreHTTPOnly() throws {
        let details = try decode(ContentDetails.self, [
            "contentType": 1, "url": "https://example.com/v", "name": "v",
            "description": "<b>d</b>",
            "video": ["videoSources": [
                ["plugin_type": "VideoUrlSource", "url": "file:///private/var/mobile/secret.mp4", "width": -5],
                ["plugin_type": "VideoUrlSource", "url": "https://media.example.com/v.mp4"],
            ]],
            "hls": ["plugin_type": "HLSSource", "url": "javascript:x"],
            "subtitles": [["name": "en", "url": "file:///etc/hosts"], ["name": "de", "url": "https://example.com/de.vtt"]],
            "id": ["pluginId": "other"],
        ])
        guard case .video(let video) = details else { return XCTFail("expected video details") }
        XCTAssertEqual(video.videoSources.map(\.url), ["", "https://media.example.com/v.mp4"])
        XCTAssertEqual(video.videoSources.first?.width, 0)
        XCTAssertEqual(video.hls?.url, "")
        XCTAssertEqual(video.subtitles.map(\.url), [nil, "https://example.com/de.vtt"])
        XCTAssertEqual(video.item.platformID.pluginId, "hostile-plugin")
    }

    func testToastsAreAttributedBoundedAndRateLimited() {
        let toast = PluginToast(pluginName: "Evil\nHummingbird", message: "Your session expired.\n" + String(repeating: "Enter your password ", count: 1_000))
        XCTAssertEqual(toast.pluginName, "Evil Hummingbird")
        XCTAssertLessThanOrEqual(toast.message.count, PluginLimits.maximumToastLength)
        XCTAssertFalse(toast.message.contains("\n"))

        let limiter = PluginToastLimiter(perMinute: 6)
        let now = Date()
        let shown = (0..<1_000).filter { _ in limiter.allow(pluginID: "flood", now: now) }.count
        XCTAssertEqual(shown, 6, "a toast flood is dropped beyond the per-minute allowance")
        XCTAssertTrue(limiter.allow(pluginID: "other", now: now), "one plugin's flood never silences another")
        XCTAssertTrue(limiter.allow(pluginID: "flood", now: now.addingTimeInterval(60)))
    }

    func testNavigableURLsCannotBeMadeFromStrings() throws {
        // `NavigableURL(contained:)` is fileprivate to containment; the only
        // other way in is a static, app-owned literal.
        XCTAssertNotNil(NavigableURL(appOwned: "https://hummingbird.app/help"))
        XCTAssertNil(NavigableURL(appOwned: "javascript:alert(1)"))
    }
}
