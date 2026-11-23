import Foundation
import PlatformSupport
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif
@testable import HummingbirdKit

/// A real VP9 + Opus WebM DASH stream (Tests/Fixtures/webm-dash, made by
/// ffmpeg) served by a plugin's request executor through the real media
/// proxy: every segment the player asks for comes back as fragmented MP4.
final class WebMDashProxyTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/webm-dash")

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, url.path)
        return data
    }

    private func boxTypes(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        return ProgressiveMP4.children(bytes, in: 0..<bytes.count).map(\.type)
    }

    func testTheFixtureIsServedAsFragmentedMP4ThroughTheProxy() async throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: caches) }
        let proxy = PluginMediaProxy(cache: UMPMediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: caches)))
        let (master, runtime) = try await WebMDashFixture.register(directory: Self.fixture, proxy: proxy)
        defer { Task { await runtime.stop() } }

        let masterText = String(decoding: try await get(master), as: UTF8.self)
        XCTAssertFalse(masterText.contains("CODECS"))
        let base = master.deletingLastPathComponent()
        for kind in ["video", "audio"] {
            let playlist = String(decoding: try await get(base.appendingPathComponent("\(kind).m3u8")), as: UTF8.self)
            let uris = playlist.split(separator: "\n").map(String.init)
                .compactMap { line -> String? in
                    if line.hasPrefix("#EXT-X-MAP:URI=\"") { return String(line.dropFirst(16).dropLast()) }
                    return line.hasPrefix("#") || line.isEmpty ? nil : line
                }
            XCTAssertEqual(uris.count, kind == "video" ? 4 : 5, "\(kind): the initialization segment and every media segment")
            for (index, uri) in uris.enumerated() {
                let data = try await get(try XCTUnwrap(URL(string: uri)))
                let types = boxTypes(data)
                if index == 0 {
                    XCTAssertEqual(types, ["ftyp", "moov"], "\(kind) init")
                    let text = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(text.contains(kind == "video" ? "vp09" : "Opus"), "\(kind) sample entry")
                } else {
                    XCTAssertEqual(types, ["moof", "mdat"], "\(kind) segment \(index)")
                }
            }
        }

        #if canImport(AVFoundation)
        // AVFoundation parses the presentation (an HLS asset's tracks are known
        // only to a player item): ready to play, or the reason it is not.
        let item = AVPlayerItem(url: master)
        let player = AVPlayer(playerItem: item)
        let end = ContinuousClock.now + .seconds(15)
        while item.status == .unknown, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(100)) }
        let formats = item.tracks.compactMap { $0.assetTrack?.mediaType.rawValue }
        print("[webm-dash] status=\(item.status.rawValue) tracks=\(formats) error=\(String(describing: item.error))")
        XCTAssertEqual(item.status, .readyToPlay, "AVFoundation opens the remuxed presentation: \(String(describing: item.error))")
        player.replaceCurrentItem(with: nil)
        #endif
        await proxy.release(master)
    }

    /// Generated manifests embed per-session URLs and parameters: keyed by
    /// the manifest text, a video never found its cached bytes again. Keyed
    /// by the source's stable identity, a later session is served from the
    /// cache even when the plugin cannot answer at all.
    func testALaterSessionOfTheSameSourceIsServedFromTheCache() async throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: caches) }
        let proxy = PluginMediaProxy(cache: UMPMediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: caches)))
        let identity = "plugin|https://example.test/v/1|single|248|vp9"

        let (first, firstRuntime) = try await WebMDashFixture.register(directory: Self.fixture, proxy: proxy,
                                                                       identity: identity, useCache: true)
        let segments = try await mediaURIs(first)
        for uri in segments { _ = try await get(try XCTUnwrap(URL(string: uri))) }
        await proxy.release(first)
        await firstRuntime.stop()

        // Another session: different manifest text, and the plugin is unreachable.
        let (second, secondRuntime) = try await WebMDashFixture.register(
            directory: Self.fixture, proxy: proxy, identity: identity, useCache: true,
            manifestSuffix: "<!-- session 2 -->", failing: true)
        for uri in try await mediaURIs(second) {
            let status = await status(of: try XCTUnwrap(URL(string: uri)))
            XCTAssertEqual(status, 200, "\(uri) came from the cache")
        }
        await proxy.release(second)
        await secondRuntime.stop()

        // Keyed by the manifest text (no identity), the same session misses.
        let (third, thirdRuntime) = try await WebMDashFixture.register(
            directory: Self.fixture, proxy: proxy, useCache: true, manifestSuffix: "<!-- session 3 -->", failing: true)
        let firstSegment = try XCTUnwrap(try await mediaURIs(third).first)
        let missed = await status(of: try XCTUnwrap(URL(string: firstSegment)))
        XCTAssertNotEqual(missed, 200, "without the identity nothing is found")
        await proxy.release(third)
        await thirdRuntime.stop()
    }

    /// Every segment URI (initialization and media) of the video and audio playlists.
    private func mediaURIs(_ master: URL) async throws -> [String] {
        let base = master.deletingLastPathComponent()
        var uris: [String] = []
        for kind in ["video", "audio"] {
            let playlist = String(decoding: try await get(base.appendingPathComponent("\(kind).m3u8")), as: UTF8.self)
            for line in playlist.split(separator: "\n").map(String.init) {
                if line.hasPrefix("#EXT-X-MAP:URI=\"") { uris.append(String(line.dropFirst(16).dropLast())) }
                else if !line.hasPrefix("#"), !line.isEmpty { uris.append(line) }
            }
        }
        return uris
    }

    /// The status within 5 s, or nil (a miss: the proxy keeps retrying an unreachable plugin).
    private func status(of url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode
    }
}
