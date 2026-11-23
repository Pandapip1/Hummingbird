import Foundation
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
        let proxy = PluginMediaProxy(cache: UMPMediaCache(directory: caches))
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
}
