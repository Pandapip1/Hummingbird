import Foundation
import DebugKit
import SwiftOpenUI

/// The app's root view with its model, for platform entry points (`Apps/iOS`, `Sources/HummingbirdGTK`).
@MainActor
public struct HummingbirdRoot: View {
    @State private var model = AppModel()
    #if canImport(SwiftUI)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    public init() {}
    public var body: some View {
        #if canImport(SwiftUI)
        #if os(tvOS)
        if ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_SCENE"] == "player" {
            TVPlayerDebugScene()
        } else {
            appRoot
        }
        #else
        appRoot
        #endif
        #else
        RootView()
            .environment(model)
            .task { await model.plugins.checkForUpdates() }
            .onOpenURL { model.handleIncomingURL($0) }
        #endif
    }

    #if canImport(SwiftUI)
    private var appRoot: some View {
        RootView()
            .environment(model)
            .task { await model.plugins.checkForUpdates() }
            .onOpenURL { model.handleIncomingURL($0) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.library.flushHistory(); model.library.persistSubscriptionState() }
            }
    }
    #endif
}

#if canImport(SwiftUI) && os(tvOS)
@MainActor
private struct TVPlayerDebugScene: View {
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
#endif
