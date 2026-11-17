import Foundation
import SwiftOpenUI
import ATAppSync
import DynamicTabbingKit

// Hummingbird's own widgets. Where platforms differ, the difference lives in
// SwiftOpenUI behind one API (adaptive controls such as `ShareContentAction`
// or `RemoteFriendlyBoundedSelection`, `browserWindowChrome`,
// `videoFullscreenPresentation`); this file only says what Hummingbird wants.
// PlatformBranchTests keeps platform conditionals out of HummingbirdKit.

/// A full-surface status presentation for loading, locked, empty, and error
/// states. Keeping the centering contract here prevents backend stack sizing
/// differences from pulling status content toward an edge.
@MainActor
struct CenteredStatusContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


@MainActor
private struct ProfileSwitcher: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openHummingbirdProfile) private var openProfile

    var body: some View {
        Menu {
            ForEach(app.localProfiles) { profile in
                Button {
                    guard profile.id != app.localProfileID else { return }
                    app.saveBrowserSession()
                    openProfile(profile.id)
                } label: {
                    Label(profileLabel(profile), systemImage: profile.id == app.localProfileID
                          ? "checkmark.circle.fill" : "person.crop.circle")
                }
            }
            Button {
                if let id = app.createLocalProfile() { openProfile(id) }
            } label: {
                Label("New Profile", systemImage: "person.crop.circle.badge.plus")
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Profiles")
    }

    private func profileLabel(_ profile: AppSyncLocalProfile) -> String {
        let digest = profile.peerService.peer.publicIdentity.stableID.rawValue
        return profile.id == app.localProfileID
            ? "Current Profile · \(digest.prefix(8))"
            : "Profile · \(digest.prefix(8))"
    }
}

extension View {
    /// The profile switcher, in a section page's own toolbar. Apply it inside
    /// the page's `NavigationStack`.
    func profileSwitcherToolbarItem() -> some View {
        browserPageToolbarItem(id: "profile.switcher", placement: .leading) { ProfileSwitcher() }
    }
}

/// Writes what is only in memory when the window stops being in front for
/// a while, and before the application quits: playback history (which
/// also reaches the synced profile's journal) and subscription refresh
/// state. One lifecycle API on every backend (SwiftOpenUI's
/// `onLifecycle`), so GTK and quitting without backgrounding flush too.
private struct ApplicationLifecycleModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let model = model
        return content.onLifecycle { event in
            switch event {
            case .phase(.background):
                model.library.flushHistory()
                model.library.persistSubscriptionState()
                let stores = model.stores
                Task.detached { await stores.flush() }
            case .sceneEnded, .willTerminate:
                // Closing the last window can quit the application with no
                // termination event reaching this window (it has already
                // ended), so both wait for the queued writes here.
                model.library.flushHistory()
                model.library.persistSubscriptionState()
                model.profileChanges.flushBeforeTermination()
                model.stores.flushBeforeTermination()
            case .phase(.active), .phase(.inactive):
                break
            }
        }
    }
}

extension View {
    func observesApplicationLifecycle(_ model: AppModel) -> some View {
        modifier(ApplicationLifecycleModifier(model: model))
    }

    @ViewBuilder
    func configuresVisualAuditRoute(_ configure: @escaping @MainActor @Sendable () -> Void) -> some View {
        #if DEBUG
        task { configure() }
        #else
        self
        #endif
    }
}


/// A scene a debug launch can ask for in place of the app
/// (`HUMMINGBIRD_DEBUG_SCENE`), to exercise one piece of UI on its own.
@MainActor
struct DebugSceneSelection<Content: View>: View {
    let stores: AppDataStores
    let content: Content

    init(stores: AppDataStores, @ViewBuilder content: () -> Content) {
        self.stores = stores
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        switch ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_SCENE"] {
        case "player": PlayerDebugScene(stores: stores)
        case "player-seek": SeekDebugScene()
        case "install-preview": InstallPreviewDebugScene()
        default: content
        }
    }
}

/// The feed's explicit "Load more" control, where rows aren't realized
/// lazily and so can't load the next page on scroll (SwiftOpenUI decides).
@MainActor
struct LoadMoreButton: View {
    let feed: FeedModel

    var body: some View {
        LoadNextPageButton(isAvailable: feed.hasMore && !feed.isLoading) {
            Task { await feed.loadMore() }
        }
    }
}

private struct BrowserWindowChromeModifier: ViewModifier {
    let model: AppModel
    @Binding var overviewPresented: Bool

    func body(content: Content) -> some View {
        let model = model
        return content.browserWindowChrome(isOverviewPresented: overviewPresented) {
            let tab = model.activeTab
            BrowserHistoryControls(
                canGoBack: tab.canGoBack,
                canGoForward: tab.canGoForward,
                goBack: { tab.goBack() },
                goForward: { tab.goForward() }
            )
        } tabStrip: {
            BrowserTabStrip().environment(model)
        }
    }
}

extension View {
    /// The window's history controls and tab strip, wherever the platform
    /// puts browser chrome (see SwiftOpenUI's `browserWindowChrome`).
    func browserWindowChrome(model: AppModel, overviewPresented: Binding<Bool>) -> some View {
        modifier(BrowserWindowChromeModifier(model: model, overviewPresented: overviewPresented))
    }
}

private struct PlayerFullscreenPresentationModifier: ViewModifier {
    let model: PlayerModel

    func body(content: Content) -> some View {
        let model = model
        return content.videoFullscreenPresentation(
            isPresented: Binding(
                get: { model.isFullscreen },
                set: { if !$0 { model.dismissFullscreen() } }
            )
        ) {
            FullscreenPlayerView(model: model)
        }
    }
}

extension View {
    /// Shows the player full screen while its model is in full screen.
    func playerFullscreenPresentation(model: PlayerModel) -> some View {
        modifier(PlayerFullscreenPresentationModifier(model: model))
    }
}

struct FocusableReadOnlyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.focusableReadOnlyValue()
    }
}

@MainActor
struct FocusableReadOnlyValue: View {
    let text: String
    var monospaced = false
    var accessibilityIdentifier: String?

    var body: some View {
        Text(text)
            .font(monospaced ? .footnote.monospaced() : .body)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            .focusableReadOnlyValue()
    }
}

/// Scans a QR code with the camera once the user allows camera access, the
/// same on every platform: SwiftOpenUI's scanner (`QRCodeScannerView`) shows
/// the camera where there is one and says so where there isn't.
@MainActor
struct QRCodeScanner: View {
    let instruction: String
    let onCode: (String) -> Void
    @Environment(AppModel.self) private var app
    @State private var access: PermissionDecision?
    @State private var hasCamera = true

    var body: some View {
        Group {
            if !hasCamera {
                ContentUnavailableView(
                    "Can’t scan with this camera", systemImage: "camera",
                    description: Text("This device’s camera can’t read QR codes right now. Enter the code instead.")
                )
            } else {
                switch access {
                case .allowed:
                    QRCodeScannerView(onCode: onCode, onUnavailable: { hasCamera = false })
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            Text(instruction).padding(10).background(.thinMaterial, in: Capsule()).padding()
                        }
                case nil:
                    ProgressView("Waiting for camera access…")
                case .notNow, .declinedOnThisDevice, .deniedBySystem:
                    ContentUnavailableView(
                        "Camera access is off", systemImage: "camera",
                        description: Text("Allow camera access for Hummingbird in Settings to scan codes, or paste the URL instead.")
                    )
                }
            }
        }
        .task {
            guard await QRCodeScanning.isAvailable() else {
                hasCamera = false
                return
            }
            // The scanner only appears after the user taps Scan, so the system
            // prompt answers that tap and can show straight away.
            access = await app.permissions.authorize(
                .camera, for: "qr-scanner", origin: .userAction, explanation: .qrScanner
            )
        }
    }
}


/// Debug builds: an invisible accessibility element naming this instance of
/// a page, so UI tests can check that switching tabs or opening the tab
/// overview never rebuilds the page (which would lose its state).
struct PageInstanceMarker: View {
    let page: String
    @State private var instance = UUID().uuidString

    var body: some View {
        #if DEBUG
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("page-instance.\(page)")
            .accessibilityLabel(instance)
        #else
        EmptyView()
        #endif
    }
}
