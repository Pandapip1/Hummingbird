#if DEBUG
import Foundation
import SwiftOpenUI

/// A plugin-generated WebM DASH source made from files (Tests/Fixtures/webm-dash):
/// a minimal plugin whose request executor returns those files, registered
/// with the real `PluginMediaProxy`, so the WebM segments are remuxed as they
/// are served exactly as for a plugin's generated source. Debug builds only:
/// it runs plugin code with an approval made here, not by the parental policy.
enum WebMDashFixture {
    /// Registers the fixture in `directory` (manifest.mpd, video/, audio/) and
    /// returns the master playlist's loopback URL, and the runtime to stop after.
    static func register(directory: URL, proxy: PluginMediaProxy) async throws -> (URL, PluginRuntime) {
        let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.mpd"), encoding: .utf8)
        var segments: [String: String] = [:]
        for kind in ["video", "audio"] {
            let folder = directory.appendingPathComponent(kind)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".webm") {
                segments["/\(kind)/\(name)"] = try Data(contentsOf: folder.appendingPathComponent(name)).base64EncodedString()
            }
        }
        let table = String(decoding: try JSONSerialization.data(withJSONObject: segments), as: UTF8.self)
        let script = """
        var SEGMENTS = \(table);
        source.enable = function () {};
        source.fixtureExecutor = function () {
            return {
                executeRequest: function (url, headers) {
                    var path = url.replace("https://grayjay.internal", "").split("?")[0];
                    var bytes = SEGMENTS[path];
                    if (!bytes) throw new ScriptException("No fixture segment " + path);
                    return bytes;
                }
            };
        };
        """
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"WebM DASH fixture","id":"webm-dash-fixture","scriptUrl":"fixture.js","version":1}"#.utf8)
        )
        let classification = CuratedSourceDatabase.shared.classification(for: config)
        guard case .success(let approval) = PolicyRules.load(
            classification, age: .range(lower: 18, upper: nil), supervision: .none, parentApproved: false
        ) else { throw PluginError.execution("The fixture source was refused") }
        let runtime = PluginRuntime(approval: approval, config: config,
                                    script: try ScriptSignature.check(script, for: config),
                                    settings: [:], auth: nil, captcha: nil)
        guard let executor = try await runtime.handleFromSource("fixtureExecutor") else {
            throw PluginError.execution("The fixture did not return an executor")
        }
        let url = try await proxy.register(manifest: manifest, runtime: runtime, executor: executor.handle,
                                           prefetch: false, useCache: false)
        return (url, runtime)
    }
}

/// UI test of generated WebM (`HUMMINGBIRD_DEBUG_SCENE=player-webm-dash`,
/// `HUMMINGBIRD_DEBUG_WEBM_DASH_DIR`): the fixture through the proxy into the
/// real player. The state reads "playing", or names what failed.
@MainActor
struct WebMDashDebugScene: View {
    @State private var player: PlayerModel
    @State private var status = "preparing"
    private let proxy: PluginMediaProxy

    init(stores: AppDataStores) {
        _player = State(wrappedValue: PlayerModel(stores: stores, backend: makeMediaBackend()))
        proxy = stores.mediaProxy
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if player.hasMedia { PlayerSurface(model: player) }
                PlayerControls(model: player, isFullscreen: false)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            Text("\(Int(player.playbackTime))").accessibilityIdentifier("debug-playback-time")
            Text(player.errorMessage.map { "error: \($0)" }
                 ?? player.waitingReason.map { "waiting: \($0)" }
                 ?? (player.isPlaying ? "playing" : status))
                .accessibilityIdentifier("debug-playback-state")
        }
        .padding()
        .task { await start() }
    }

    private func start() async {
        guard let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_WEBM_DASH_DIR"] else {
            status = "failed: HUMMINGBIRD_DEBUG_WEBM_DASH_DIR is not set"
            return
        }
        do {
            let (url, _) = try await WebMDashFixture.register(directory: URL(fileURLWithPath: path), proxy: proxy)
            player.localPlaybackForTesting = { _ in try LocalPlayback(video: url, servedBy: .generatedMedia) }
            let source = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"url":"https://debug.invalid/webm.mpd"}"#.utf8))
            await player.select(PlaybackOption(id: "webm-dash", label: "WebM", kind: .hls, video: source, audio: nil, height: 180))
            if !player.isPlaying { player.togglePlayback() }
            status = "paused"
        } catch {
            status = "failed: \(error.localizedDescription)"
        }
    }
}
#endif
