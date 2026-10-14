import Foundation
import DebugKit
import SwiftOpenUI
import ATAppSync

/// The app's root view with its model, for platform entry points (`Apps/iOS`, `Sources/HummingbirdGTK`).
@MainActor
public struct HummingbirdRoot: View {
    @State private var model: AppModel
    public init() {
        _model = State(wrappedValue: AppModel())
        // Start the opt-in debug transport as soon as the root is created.
        // Relying only on a view task made the server unavailable before (and
        // occasionally throughout) early navigation failures on macOS.
        DebugServer.shared.startFromEnvironment()
    }

    private init(profileID: UUID, persistence: AppPersistenceSnapshot) {
        _model = State(wrappedValue: AppModel(
            persistence: persistence, localProfileID: profileID
        ))
        DebugServer.shared.startFromEnvironment()
    }

    private init(persistence: AppPersistenceSnapshot) {
        _model = State(wrappedValue: AppModel(persistence: persistence))
        DebugServer.shared.startFromEnvironment()
    }

    /// Loads and decodes persisted state away from the main actor before any
    /// observable model is constructed.
    public static func prepared() async -> HummingbirdRoot {
        let persistence = await AppPersistenceSnapshot.load()
        return HummingbirdRoot(persistence: persistence)
    }

    public static func prepared(profileID: UUID) async -> HummingbirdRoot {
        let persistence = await AppPersistenceSnapshot.load(profileID: profileID)
        return HummingbirdRoot(profileID: profileID, persistence: persistence)
    }
    public var body: some View {
        DebugSceneSelection {
            RootView()
                .environment(model)
                .configuresVisualAuditRoute(configureVisualAuditRoute)
                .task { await model.plugins.checkForUpdates() }
                .task { configureDebugServer() }
                .onOpenURL { model.handleIncomingURL($0) }
                .observesApplicationLifecycle(model)
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

    private func configureDebugServer() {
        DebugServer.shared.registerProbe("activeTab") { model.activeTabID.uuidString }
        DebugServer.shared.registerProbe("playing") { String(model.activePlayerForDebug?.isPlaying ?? false) }
        DebugServer.shared.registerProbe("preparing") { String(model.activePlayerForDebug?.isPreparing ?? false) }
        DebugServer.shared.registerProbe("playerError") { model.activePlayerForDebug?.errorMessage ?? "" }
        DebugServer.shared.registerProbe("playerTime") { String(model.activePlayerForDebug?.playbackTime ?? 0) }
        DebugServer.shared.registerProbe("playerDuration") { String(model.activePlayerForDebug?.duration ?? 0) }
        DebugServer.shared.registerAction("togglePlayback") { model.activePlayerForDebug?.togglePlayback() }
        DebugServer.shared.registerAction("seekForward60") { model.activePlayerForDebug?.skip(by: 60) }
        DebugServer.shared.registerAction("seekBackward30") { model.activePlayerForDebug?.skip(by: -30) }
        if let url = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_CONTENT_URL"], !url.isEmpty {
            DebugServer.shared.registerAction("openDebugContent") {
                model.openInNewTab(.content(url), title: "Debug Video")
            }
        }
        DebugServer.shared.startFromEnvironment()
    }
}

#if canImport(SwiftUI) && !BACKEND_GTK && os(tvOS)
@MainActor
struct TVPlayerDebugScene: View {
    @State private var player = PlayerModel(backend: AVMediaBackend())

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
        .task {
            DebugServer.shared.registerProbe("fullscreen") { String(player.isFullscreen) }
            DebugServer.shared.registerProbe("playing") { String(player.isPlaying) }
            DebugServer.shared.registerProbe("focusedItem") { currentFocusedItemDescription() }
            DebugServer.shared.registerAction("toggleFullscreen") { player.toggleFullscreen() }
            DebugServer.shared.registerAction("togglePlayback") { player.togglePlayback() }
            DebugServer.shared.startFromEnvironment()
        }
    }

    private func currentFocusedItemDescription() -> String {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return "none (no key window)" }
        guard let item = window.windowScene?.focusSystem?.focusedItem else { return "none" }
        let label = (item as? UIView)?.accessibilityLabel ?? ""
        return "\(type(of: item)) \(label)".trimmingCharacters(in: .whitespaces)
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
    let pictureInPictureSupported = false

    func togglePlayback() { isPlaying.toggle() }
    func skip(by seconds: Double) { seek(to: playbackTime + seconds) }
    func seek(to seconds: Double) { playbackTime = min(max(0, seconds), duration) }
    func setPlaybackRate(_ rate: Float) { playbackRate = rate }
    func startPictureInPicture() {}
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
