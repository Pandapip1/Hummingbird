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

#if canImport(SwiftUI) && !BACKEND_GTK && os(tvOS)
@MainActor
struct TVPlayerDebugScene: View {
    @State private var player: PlayerModel

    init(stores: AppDataStores) {
        _player = State(wrappedValue: PlayerModel(stores: stores, backend: AVMediaBackend()))
    }

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
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
struct TVSeekDebugScene: View {
    @State private var player = TVSeekDebugModel()

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
private final class TVSeekDebugModel: AdvancedVideoPlayerControlling {
    let title = "Seek control test"
    var playbackTime: Double = 60
    let duration: Double = 600
    var isPlaying = false
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
}

@MainActor
struct TVInstallPreviewDebugScene: View {
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
#endif
