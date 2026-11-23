import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// iOS closes a suspended app's listening sockets and their connections. Every
/// loopback listener registers with `LoopbackLifecycle`, which binds them all
/// again, on the ports the player and the plugins already use, when the app
/// comes back.
final class SuspensionResumeTests: XCTestCase {
    private func get(_ url: URL) async -> Int? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return ((try? await session.data(from: url))?.1 as? HTTPURLResponse)?.statusCode
    }

    func testTheMediaServerComesBackOnItsPortAfterAReclaim() async throws {
        let server = LocalMediaServer()
        var presentation = LocalMediaServer.Presentation()
        presentation.playlists["index.m3u8"] = "#EXTM3U\n"
        let (_, base) = try await server.register(presentation)
        let url = base.appendingPathComponent("index.m3u8")
        let firstStatus = await get(url)
        XCTAssertEqual(firstStatus, 200)

        await server.reclaimAsSuspensionWould()
        let whileSuspended = await get(url)
        XCTAssertNil(whileSuspended, "reclaimed as iOS does: nothing listens until the app is back")

        let move = await server.resumeAfterSuspension()
        XCTAssertNil(move, "the same port: the player's URLs stay valid")
        let afterResume = await get(url)
        XCTAssertEqual(afterResume, 200)
    }

    func testTheGeneratedMediaProxyComesBackOnItsPortAfterAReclaim() async throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: caches) }
        let proxy = PluginMediaProxy(cache: UMPMediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: caches)))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/webm-dash")
        let (master, runtime) = try await WebMDashFixture.register(directory: fixture, proxy: proxy)
        defer { Task { await runtime.stop() } }
        let before = await get(master)
        XCTAssertEqual(before, 200)

        await proxy.reclaimAsSuspensionWould()
        let whileSuspended = await get(master)
        XCTAssertNil(whileSuspended)

        let move = await proxy.resumeAfterSuspension()
        XCTAssertNil(move, "the same port: its playlists name it")
        let after = await get(master)
        XCTAssertEqual(after, 200, "the presentation is served again")
    }

    func testAPluginsEgressProxyComesBackOnItsPort() async throws {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(
            #"{"name":"P","id":"egress-resume","scriptUrl":"x.js","version":1,"allowUrls":["example.test"]}"#.utf8))
        let proxy = try PluginEgressProxy.start(policy: PluginNetworkPolicy(config: config, approvals: []))
        defer { proxy.close() }
        let reachableBefore = await LoopbackLifecycle.accepts(port: proxy.port)
        XCTAssertTrue(reachableBefore)
        await proxy.reclaimAsSuspensionWould()
        let reachableWhileSuspended = await LoopbackLifecycle.accepts(port: proxy.port)
        XCTAssertFalse(reachableWhileSuspended)
        _ = await proxy.resumeAfterSuspension()
        let reachableAfter = await LoopbackLifecycle.accepts(port: proxy.port)
        XCTAssertTrue(reachableAfter, "the plugin's sessions are configured with this port")
    }

    /// Every listening socket in the app is a registered `SuspendedResource`,
    /// so a new one cannot be left out of resuming. The LAN pairing listener
    /// is the exception: it lives for one pairing, not across a suspension.
    func testEveryListenerRegistersWithTheLifecycle() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/HummingbirdKit")
        let exceptions: Set<String> = ["CredentialPairing.swift"]
        var listeners: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift", !exceptions.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("ServerBootstrap(") else { continue }
            listeners.append(file.lastPathComponent)
            XCTAssertTrue(text.contains("LoopbackLifecycle.shared.register("), "\(file.lastPathComponent) registers its listener")
            XCTAssertTrue(text.contains(": SuspendedResource"), "\(file.lastPathComponent) resumes after a suspension")
        }
        XCTAssertEqual(Set(listeners), ["LocalMediaServer.swift", "PluginMediaProxy.swift", "PluginEgressProxy.swift"])
    }
}
