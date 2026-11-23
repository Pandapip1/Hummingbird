import Foundation
import SwiftOpenUI
import ATAppSync

/// The app's root view with its model, for platform entry points (`Apps/iOS`, `Sources/HummingbirdGTK`).
@MainActor
public struct HummingbirdRoot: View {
    @State private var model: AppModel
    /// Opens the profile `stores` last selected, without restoring its state.
    public init(stores: AppDataStores) {
        self.init(stores: stores, profileID: nil, persistence: .empty, profile: nil)
    }

    private init(stores: AppDataStores, profileID: UUID?, persistence: AppPersistenceSnapshot,
                 profile: OpenedLocalProfile?, pluginCredentials: PreloadedPluginCredentials? = nil) {
        _model = State(wrappedValue: AppModel(
            persistence: persistence, stores: stores, localProfileID: profileID, openedProfile: profile,
            pluginCredentials: pluginCredentials
        ))
    }

    /// Loads and decodes persisted state, and opens the local profile, away
    /// from the main actor before any observable model is constructed. Without a `profileID`, opens the
    /// profile `stores` last selected.
    public static func prepared(stores: AppDataStores, profileID: UUID? = nil) async -> HummingbirdRoot {
        let persistence = await AppPersistenceSnapshot.load(stores: stores, profileID: profileID)
        // Identity keys and the change journal are read away from the main
        // actor too; keychain reads can take a while. After the snapshot, as
        // before, since opening may create the first profile.
        let profile = await OpenedLocalProfile.openInBackground(stores: stores, localProfileID: profileID)
        let pluginCredentials = await PreloadedPluginCredentials.load(
            pluginIDs: persistence.plugins.map(\.id), from: stores.credentialStore,
            namespace: profile.storagePrefix
        )
        return HummingbirdRoot(
            stores: stores, profileID: profileID, persistence: persistence, profile: profile,
            pluginCredentials: pluginCredentials
        )
    }
    public var body: some View {
        DebugSceneSelection(stores: model.stores) {
            RootView()
                .environment(model)
                .configuresVisualAuditRoute(configureVisualAuditRoute)
                .task { await model.plugins.checkForUpdates(origin: .settings) }
                .onOpenURL { model.handleIncomingURL($0) }
                .observesApplicationLifecycle(model)
                // Closing the window (or quitting) stops its players: nothing plays from a closed window.
                .onSceneEnd { model.closeWindow() }
        }
    }

    private func configureVisualAuditRoute() {
        guard let name = ProcessInfo.processInfo.environment["HUMMINGBIRD_VISUAL_AUDIT_ROUTE"] else { return }
        let route: Route
        switch name {
        case "subscriptions": route = .subscriptions
        case "search": route = .search
        case "library": route = .library
        case "sources": route = .sources
        case "settings": route = .settings
        default: return
        }
        guard model.activeTab.current != route else { return }
        model.activeTab.push(route, title: name.capitalized)
    }
}

// Debug scenes (`HUMMINGBIRD_DEBUG_SCENE`, see `DebugSceneSelection`): one piece of
// UI on its own, on every platform. The player uses the platform's own
// media backend.
@MainActor
struct PlayerDebugScene: View {
    @State private var player: PlayerModel

    init(stores: AppDataStores) {
        _player = State(wrappedValue: PlayerModel(stores: stores))
    }

    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.12).ignoresSafeArea()
            ZStack {
                Color.black
                PlayerSurface(model: player)
                PlayerControls(model: player, isFullscreen: false)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 1_280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 24)
        }
        .task { HummingbirdDebug.standalonePlayer = player }
    }
}

@MainActor
struct SeekDebugScene: View {
    @State private var player = SeekDebugModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AdvancedVideoPlayerControls(model: player, isFullscreen: false, availableWidth: 1_200) { _ in
                EmptyView()
            }
        }
    }
}

@MainActor
@Observable
private final class SeekDebugModel: AdvancedVideoPlayerControlling {
    let title = "Seek control test"
    @ObservationIgnored let clock = PlaybackClock(time: 60)
    var playbackTime: Double {
        get { clock.time }
        set { clock.time = newValue }
    }
    let duration: Double = 600
    var isPlaying = false
    var waitingReason: String? { nil }
    var playbackRate: Float = 1
    let pictureInPictureState = PictureInPictureState.unsupported
    let isMediaReady = true
    var scrubberContent: ScrubberContent { ScrubberContent(duration: duration) }
    func jumpToLive() {}

    func togglePlayback() { isPlaying.toggle() }
    func skip(by seconds: Double) { seek(to: playbackTime + seconds) }
    func seek(to seconds: Double) { playbackTime = min(max(0, seconds), duration) }
    func setPlaybackRate(_ rate: Float) { playbackRate = rate }
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func toggleFullscreen() {}
    func toggleCaptions() {}
    func controlsVisibilityChanged(_ visible: Bool) {}
}

@MainActor
struct InstallPreviewDebugScene: View {
    private let preview: InstallPreview = {
        let urls = (0..<30).map { "https://audit-\($0).example.com/path" }
        let json = """
        {"name":"Preview scroll test","description":"Every allowed host must remain reachable before installation.","author":"Hummingbird","version":1,"id":"preview-scroll-test","allowUrls":\(try! String(data: JSONEncoder().encode(urls), encoding: .utf8)!)}
        """
        let config = try! JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return InstallPreview(config: config, script: "", iconURL: nil, warnings: [], existing: nil)
    }()

    var body: some View {
        NavigationStack {
            PreviewView(preview: preview)
                .navigationTitle("Add source")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") {} }
                    ToolbarItem(placement: .confirmationAction) { Button("Install") {} }
                }
        }
    }
}
/// UI tests of the surface handover (`HUMMINGBIRD_DEBUG_SCENE=player-fullscreen`):
/// a real player with the real surfaces and controls, playing a clip
/// generated on the device, so no plugin or network is involved.
@MainActor
struct FullscreenHandoverDebugScene: View {
    @State private var player: PlayerModel
    @State private var status = "preparing"

    init(stores: AppDataStores) {
        _player = State(wrappedValue: PlayerModel(stores: stores, backend: makeMediaBackend()))
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if player.hasMedia { PlayerSurface(model: player) }
                PlayerControls(model: player, isFullscreen: false)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .playerFullscreenPresentation(model: player)
            Text("\(Int(player.playbackTime))").accessibilityIdentifier("debug-playback-time")
            // Names what is wrong when it is not "playing", so a failing test says why.
            Text(player.errorMessage.map { "error: \($0)" }
                 ?? player.waitingReason.map { "waiting: \($0)" }
                 ?? (player.isPlaying ? "playing" : status == "loaded" ? "paused" : status))
                .accessibilityIdentifier("debug-playback-state")
        }
        .padding()
        .task { await start() }
    }

    private func start() async {
        do {
            let shade = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_CLIP_SHADE"].flatMap(Int.init)
            let clip = try await DebugMediaClip.make(shade: shade)
            player.localPlaybackForTesting = { _ in try LocalPlayback(video: clip, servedBy: .mediaCache) }
            let source = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"url":"https://debug.invalid/clip.mp4"}"#.utf8))
            await player.select(PlaybackOption(id: "debug-clip", label: "Clip", kind: .hls, video: source, audio: nil, height: 180))
            if !player.isPlaying { player.togglePlayback() }
            status = "loaded"
        } catch {
            status = "failed: \(error.localizedDescription)"
        }
    }
}

