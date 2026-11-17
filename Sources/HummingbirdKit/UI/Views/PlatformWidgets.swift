import Foundation
import SwiftOpenUI
import ATAppSync
import DynamicTabbingKit
#if os(macOS) && !BACKEND_GTK
import AppKit
#endif
#if os(tvOS)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

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
struct ExternalURLLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        Link(destination: destination, label: label)
        #else
        Button { SystemServices.openURL(destination) } label: { label() }
        #endif
    }
}

#if os(macOS) && !BACKEND_GTK
private final class HummingbirdTabBarAccessoryViewController: NSTitlebarAccessoryViewController {}

private final class NotificationObserverTokens: @unchecked Sendable {
    var values: [NSObjectProtocol] = []

    deinit {
        values.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Owns the tab strip as window chrome. SwiftUI representables can be rebuilt
/// or briefly overlap during navigation, so installation is reconciled at the
/// NSWindow level rather than treating each representable as the accessory's
/// owner.
@MainActor
final class WindowTabBarAccessoryManager {
    // BrowserTabBar's label, tab padding, capsule padding, and outer padding
    // require about 37 points at the default macOS font size. Leave one point
    // for pixel rounding rather than clipping the capsule's lower edge.
    static let height: CGFloat = 38

    private weak var window: NSWindow?
    private let accessory = HummingbirdTabBarAccessoryViewController()
    private let hosting: NSHostingController<AnyView>
    private var owners: [UUID: Bool] = [:]
    private let observers = NotificationObserverTokens()

    init(window: NSWindow, app: AppModel) {
        self.window = window
        hosting = NSHostingController(rootView: AnyView(BrowserTabStrip().environment(app)))
        accessory.view = hosting.view
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 0
        hosting.view.autoresizingMask = [.width]

        let center = NotificationCenter.default
        observers.values = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reconcile() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) {
                [weak self] _ in self?.reconcileAfterFullScreenTransition()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) {
                [weak self] _ in self?.reconcileAfterFullScreenTransition()
            },
        ]
    }

    var isUnused: Bool { owners.isEmpty }

    func attach(owner: UUID, app: AppModel, isHidden: Bool = false) {
        owners[owner] = isHidden
        hosting.rootView = AnyView(BrowserTabStrip().environment(app))
        reconcile()
    }

    func detach(owner: UUID) {
        owners[owner] = nil
        guard owners.isEmpty, let window else { return }
        if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    func reconcile() {
        guard !owners.isEmpty, let window, window.styleMask.contains(.titled) else { return }
        guard owners.values.contains(false) else {
            if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            return
        }
        // Remove abandoned Hummingbird accessories left by a replaced SwiftUI
        // coordinator before ensuring this manager's accessory is installed.
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            let candidate = window.titlebarAccessoryViewControllers[index]
            if candidate is HummingbirdTabBarAccessoryViewController, candidate !== accessory {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
        let width = max(0, window.contentLayoutRect.width)
        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        accessory.view.frame = hosting.view.frame
        if !window.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) {
            window.addTitlebarAccessoryViewController(accessory)
        }
        window.contentView?.needsLayout = true
    }

    private nonisolated func reconcileAfterFullScreenTransition() {
        // AppKit can report its old content-layout rect until the following
        // main-run-loop turn after a fullscreen transition.
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }
}

@MainActor
private final class WindowTabBarAccessoryRegistry {
    static let shared = WindowTabBarAccessoryRegistry()
    private struct Entry { weak var window: NSWindow?; let manager: WindowTabBarAccessoryManager }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func manager(for window: NSWindow, app: AppModel) -> WindowTabBarAccessoryManager {
        purgeReleasedWindows()
        let key = ObjectIdentifier(window)
        if let entry = entries[key], entry.window === window { return entry.manager }
        let manager = WindowTabBarAccessoryManager(window: window, app: app)
        entries[key] = Entry(window: window, manager: manager)
        return manager
    }

    func releaseManager(for window: NSWindow) {
        let key = ObjectIdentifier(window)
        if entries[key]?.manager.isUnused == true { entries[key] = nil }
        purgeReleasedWindows()
    }

    private func purgeReleasedWindows() {
        entries = entries.filter { $0.value.window != nil }
    }
}

/// Mounts `BrowserTabStrip` as a window-managed titlebar accessory so it
/// occupies its own row below the toolbar, matching Safari and iTerm2.
@MainActor
struct TabBarAccessoryInstaller: NSViewRepresentable {
    let app: AppModel
    let isHidden: Bool

    func makeNSView(context: Context) -> _WindowObserverView {
        let v = _WindowObserverView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: _WindowObserverView, context: Context) {
        context.coordinator.app = app
        context.coordinator.isHidden = isHidden
        context.coordinator.move(to: nsView.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator(app: app, isHidden: isHidden) }

    static func dismantleNSView(_ nsView: _WindowObserverView, coordinator: Coordinator) {
        coordinator.move(to: nil)
        nsView.coordinator = nil
    }

    @MainActor
    final class Coordinator {
        var app: AppModel
        var isHidden: Bool
        private let owner = UUID()
        private weak var installedWindow: NSWindow?

        init(app: AppModel, isHidden: Bool) {
            self.app = app
            self.isHidden = isHidden
        }

        func move(to window: NSWindow?) {
            if installedWindow !== window, let old = installedWindow {
                let registry = WindowTabBarAccessoryRegistry.shared
                let manager = registry.manager(for: old, app: app)
                manager.detach(owner: owner)
                registry.releaseManager(for: old)
            }
            guard let window else { installedWindow = nil; return }
            let manager = WindowTabBarAccessoryRegistry.shared.manager(for: window, app: app)
            manager.attach(owner: owner, app: app, isHidden: isHidden)
            installedWindow = window
        }
    }

    @MainActor
    final class _WindowObserverView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.move(to: window)
        }
    }
}
#endif

#if os(macOS) && !BACKEND_GTK
@MainActor
final class MacOSFullscreenPresenter: NSObject, NSWindowDelegate {
    private weak var model: PlayerModel?
    private var window: NSWindow?

    func install(on model: PlayerModel) {
        self.model = model
        model.installFullscreenPresenter(
            present: { [weak self] in self?.open() },
            dismiss: { [weak self] in self?.requestClose() }
        )
    }

    func uninstall() {
        model?.removeFullscreenPresenter()
        requestClose()
        model = nil
    }

    private func open() {
        guard window == nil, let model else { return }
        let hosting = NSHostingController(
            rootView: FullscreenPlayerView(model: model).preferredColorScheme(.dark)
        )
        let w = NSWindow(contentViewController: hosting)
        // A dedicated borderless window makes fullscreen player chrome behave
        // like native media apps: no stranded titlebar/traffic-light strip.
        w.styleMask = [.borderless, .resizable]
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = .fullScreenPrimary
        w.delegate = self
        w.setContentSize(NSSize(width: 1280, height: 720))
        w.center()
        w.makeKeyAndOrderFront(nil)
        w.toggleFullScreen(nil)
        window = w
        model.fullscreenDidChange(true)
    }

    private func requestClose() {
        guard let w = window else { return }
        if w.styleMask.contains(.fullScreen) {
            // Exit fullscreen first; windowDidExitFullScreen will close the window.
            w.toggleFullScreen(nil)
        } else {
            performClose(w)
        }
    }

    private func performClose(_ w: NSWindow) {
        window = nil
        w.delegate = nil
        w.close()
        model?.fullscreenDidChange(false)
    }

    nonisolated func windowDidExitFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let w = window else { return }
            performClose(w)
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard window != nil else { return }
            window = nil
            model?.fullscreenDidChange(false)
        }
    }
}
#endif

@MainActor
struct LazyContentStack<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        LazyVStack(alignment: alignment, spacing: spacing ?? 8, content: content)
        #else
        VStack(alignment: alignment, spacing: spacing ?? 8, content: content)
        #endif
    }
}

extension View {
    func hiddenListRowSeparator() -> some View {
        #if os(tvOS)
        self
        #else
        listRowSeparator(.hidden)
        #endif
    }

    /// Automatic pagination is valid only for backends with lazy row realization.
    func loadsNextPageWhenLast(_ isLast: Bool, _ load: @escaping () async -> Void) -> some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        onAppear { if isLast { Task { await load() } } }
        #else
        self
        #endif
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
            case .phase(.active):
                model.applicationBecameActive()
            case .phase(.inactive):
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
        #if canImport(SwiftUI) && !BACKEND_GTK && os(iOS)
        switch ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_SCENE"] {
        case "player-fullscreen": FullscreenHandoverDebugScene(stores: stores)
        default: content
        }
        #elseif canImport(SwiftUI) && !BACKEND_GTK && os(tvOS)
        switch ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_SCENE"] {
        case "player": TVPlayerDebugScene(stores: stores)
        case "player-seek": TVSeekDebugScene()
        case "install-preview": TVInstallPreviewDebugScene()
        default: content
        }
        #else
        content
        #endif
    }
}

@MainActor
struct LoadMoreButton: View {
    let feed: FeedModel

    var body: some View {
        #if canImport(SwiftUI) && !BACKEND_GTK
        EmptyView()
        #else
        if feed.hasMore && !feed.isLoading {
            Button("Load more") { Task { await feed.loadMore() } }
                .frame(maxWidth: .infinity)
        }
        #endif
    }
}

struct AdaptiveMenuItem<Value>: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let value: Value
}

@MainActor
struct AdaptiveActionMenu<Value>: View {
    let title: String
    let systemImage: String
    let items: [AdaptiveMenuItem<Value>]
    let action: @MainActor @Sendable (Value, String) -> Void

    var body: some View {
        #if os(tvOS)
        NativeActionMenuButton(
            title: title,
            systemImage: systemImage,
            items: items,
            action: action
        )
        #else
        Menu {
            ForEach(items) { item in
                Button { action(item.value, item.title) } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
        .accessibilityLabel(title)
        #endif
    }
}

#if os(tvOS)
@MainActor
private struct NativeActionMenuButton<Value>: UIViewRepresentable {
    let title: String
    let systemImage: String
    let items: [AdaptiveMenuItem<Value>]
    let action: @MainActor @Sendable (Value, String) -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemImage), for: .normal)
        button.accessibilityLabel = title
        button.showsMenuAsPrimaryAction = true
        button.menu = makeMenu()
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.menu = makeMenu()
    }

    private func makeMenu() -> UIMenu {
        UIMenu(title: title, children: items.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in
                Task { @MainActor in action(item.value, item.title) }
            }
        })
    }
}
#endif

/// The window toolbar's history controls for the selected tab, on desktop
/// windows. Touch and TV layouts have them in the tab container's bar.
@MainActor
struct BrowserTopToolbar: ToolbarContent {
    let tab: BrowserTab

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            BrowserHistoryControls(
                canGoBack: tab.canGoBack,
                canGoForward: tab.canGoForward,
                goBack: { tab.goBack() },
                goForward: { tab.goForward() }
            )
        }
    }
}

private struct BrowserWindowChromeModifier: ViewModifier {
    let model: AppModel
    @Binding var overviewPresented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS) || os(tvOS)
        content
        #else
        content
            .toolbar {
                if !overviewPresented {
                    BrowserTopToolbar(tab: model.activeTab)
                }
            }
            .background {
                #if os(macOS) && !BACKEND_GTK
                TabBarAccessoryInstaller(app: model, isHidden: overviewPresented)
                    .frame(width: 0, height: 0)
                #endif
            }
        #endif
    }
}

extension View {
    func browserWindowChrome(model: AppModel, overviewPresented: Binding<Bool>) -> some View {
        modifier(BrowserWindowChromeModifier(model: model, overviewPresented: overviewPresented))
    }
}

private struct PlayerFullscreenPresentationModifier: ViewModifier {
    let model: PlayerModel
    #if os(macOS) && !BACKEND_GTK
    @State private var presenter = MacOSFullscreenPresenter()
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS) && !BACKEND_GTK
        content
            .onAppear { presenter.install(on: model) }
            .onDisappear { presenter.uninstall() }
        #elseif canImport(UIKit)
        // AVPlayerViewController owns fullscreen presentation on UIKit.
        content
        #else
        let isFullscreen = model.isFullscreen
        content.fullScreenCover(
            isPresented: Binding(get: { isFullscreen }, set: { if !$0 { model.dismissFullscreen() } })
        ) {
            FullscreenPlayerView(model: model)
        }
        #endif
    }
}

extension View {
    func playerFullscreenPresentation(model: PlayerModel) -> some View {
        modifier(PlayerFullscreenPresentationModifier(model: model))
    }
}

// Platform-specific UI belongs in this file. Feature screens consume widgets
// named for the behavior they provide instead of knowing which OS provides it.

extension View {
    @ViewBuilder
    func detailNavigationStyle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func editableCollectionToolbar(id: String) -> some View {
        #if os(iOS)
        browserPageToolbarItem(id: id, placement: .trailing) { EditButton() }
        #else
        self
        #endif
    }

    @ViewBuilder
    func destructiveRowAction(_ title: String, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        swipeActions { Button(title, role: .destructive, action: action) }
        #endif
    }

    @ViewBuilder
    func urlEntryStyle() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).keyboardType(.URL)
        #else
        self
        #endif
    }

    @ViewBuilder
    func settingsTextEntryStyle() -> some View {
        #if os(tvOS)
        self
        #else
        textFieldStyle(.roundedBorder)
        #endif
    }

    @ViewBuilder
    func focusableReadOnlyValue() -> some View {
        #if os(tvOS)
        focusable()
        #else
        self
        #endif
    }

    @ViewBuilder
    func immersiveVideoDetailStyle() -> some View {
        #if os(iOS)
        ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

struct FocusableReadOnlyModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.focusableReadOnlyValue()
    }
}

@MainActor
struct RemoteFriendlyBoundedSelection: View {
    let title: String
    @Binding var value: Int
    let values: [Int]
    let zeroLabel: String
    let step: Int

    var body: some View {
        #if os(tvOS)
        Picker(title, selection: $value) {
            Text(zeroLabel).tag(0)
            ForEach(values.filter { $0 != 0 }, id: \.self) { Text(String($0)).tag($0) }
        }
        #else
        Stepper("\(title): \(value == 0 ? zeroLabel.lowercased() : String(value))",
                value: $value, in: (values.min() ?? 0)...(values.max() ?? 0), step: step)
        #endif
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

@MainActor
struct ShareContentAction<Label: View>: View {
    let item: URL?
    @ViewBuilder let label: () -> Label

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if let item { ShareLink(item: item, label: label) }
        #endif
    }
}

@MainActor
struct SettingsDetailContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS) && !BACKEND_GTK
        ScrollView { content().frame(maxWidth: .infinity) }.defaultScrollAnchor(.top)
        #else
        content()
        #endif
    }
}

enum QRCodeScanning {
    /// Whether this device has a camera. Looking up capture devices can block
    /// for a noticeable time, so it never runs on the main thread.
    static func isAvailable() async -> Bool {
        #if (os(iOS) || os(macOS)) && !BACKEND_GTK
        await Task.detached(priority: .userInitiated) {
            AVCaptureDevice.default(for: .video) != nil
        }.value
        #else
        false
        #endif
    }
}

@MainActor
struct QRCodeScanner: View {
    let instruction: String
    let onCode: (String) -> Void
    #if (os(iOS) || os(macOS)) && !BACKEND_GTK
    @Environment(AppModel.self) private var app
    @State private var access: PermissionDecision?
    @State private var hasCamera = true
    #endif

    var body: some View {
        #if (os(iOS) || os(macOS)) && !BACKEND_GTK
        Group {
            if !hasCamera {
                ContentUnavailableView(
                    "Can’t scan with this camera", systemImage: "camera",
                    description: Text("This device’s camera can’t read QR codes right now. Enter the code instead.")
                )
            } else {
            switch access {
            case .allowed:
                QRScannerView(onCode: onCode, onUnavailable: { hasCamera = false })
                    #if os(iOS)
                    .ignoresSafeArea()
                    #endif
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
        #else
        Text("QR scanning is not available on this platform. Paste the URL instead.")
        #endif
    }
}

@MainActor
struct DocumentTransferControls: View {
    let title: String
    let exportURL: URL?
    let exportLabel: String
    let importLabel: String
    let status: String?
    let requestImport: () -> Void

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Section(title) {
            if let exportURL {
                ShareLink(item: exportURL) { Label(exportLabel, systemImage: "square.and.arrow.up") }
            } else {
                Label("Preparing export…", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            Button(action: requestImport) {
                Label(importLabel, systemImage: "square.and.arrow.down")
            }
            if let status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        }
        #endif
    }
}

private struct JSONDocumentImporter: ViewModifier {
    @Binding var isPresented: Bool
    let importBackup: (URL) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importBackup(url)
        }
        #endif
    }
}

extension View {
    func jsonDocumentImporter(isPresented: Binding<Bool>, onImport: @escaping (URL) -> Void) -> some View {
        modifier(JSONDocumentImporter(isPresented: isPresented, importBackup: onImport))
    }

    @ViewBuilder
    func preparesDocumentExport(id: String, _ prepare: @escaping @Sendable () async -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        task(id: id, prepare)
        #endif
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
