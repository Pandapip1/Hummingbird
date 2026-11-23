import HummingbirdKit
import PluginEngine
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4
#if BACKEND_GTK_WEBKIT
import WebKit
#endif
import CGTK
import CGTKBridge
import Foundation

@MainActor
struct HummingbirdGTKApp: App {
    var body: some Scene {
        WindowGroup("Hummingbird", for: UUID.self) { profileID in
            GTKProfileRoot(profileID: profileID.wrappedValue)
        }
        .hummingbirdCommands()
    }
}

@MainActor
private struct GTKProfileRoot: View {
    let profileID: UUID?

    var body: some View {
        PreparedHummingbirdRoot(
            stores: liveStores(), profileID: profileID, opensProfilesInNewWindows: true
        )
    }
}

/// The user's real data. This entry point is the only place that opens it.
private func liveStores() -> AppDataStores {
    #if canImport(Security)
    // This standalone backend-development executable is not the provisioned
    // native app bundle. Give it its own Keychain service so macOS never tries
    // to authorize every native-app legacy item against a different executable
    // identity. It remains a real Keychain store, not a plaintext debug store.
    AppDataStores.live(credentialServiceNamespace: "gtk")
    #else
    AppDataStores.live()
    #endif
}

// Started by itself as a plugin host (PluginExecutionLimits.installPlatformIsolation): serve JavaScript
// contexts on stdin/stdout and nothing else, before any GTK, WebKit or app state exists.
if CommandLine.arguments.dropFirst().first == "--plugin-host" { PluginHostServer.runAsProcess() }

MainActor.assumeIsolated {
    PluginExecutionLimits.installPlatformIsolation(appBundleIdentifier: nil)
    liveStores().registerCredentialVault()
    // Crashes recorded by systemd-coredump since the last run arrive as
    // MetricKit diagnostics (SwiftOpenUI's MetricKit on Linux).
    PerformanceReports.start(stores: liveStores())
    // Register backend fonts before the WebKit bootstrap initializes GTK/Pango's
    // default font map, otherwise symbol labels are permanently resolved through
    // a fallback font for this process.
    gtkRegisterBundledIconFont()
    #if BACKEND_GTK_WEBKIT
    // JavaScriptCoreGTK and WebKitGTK share WTF process-global state. Start a
    // WebKit page on the GTK thread before plugin runtimes create JSC contexts
    // on their serial worker queues.
    do {
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        // The page only loads the inline HTML below, so it gets its own
        // ephemeral network session: nothing is read from or written to the
        // persistent WebKit data directory.
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WebPage(configuration: configuration)
        let widget = widgetFromOpaque(WebView(page).gtkCreateWidget())
        let window = gtk_window_new()!
        gtk_window_set_decorated(windowPointer(window), 0)
        gtk_widget_set_focusable(window, 0)
        gtk_window_set_default_size(windowPointer(window), 1, 1)
        gtk_widget_set_opacity(window, 0)
        gtk_window_set_child(windowPointer(window), widget)
        gtk_widget_set_visible(window, 1)
        page.load(html: "<title>Hummingbird WebKit bootstrap</title>")
        let deadline = Date().addingTimeInterval(10)
        while page.title != "Hummingbird WebKit bootstrap", Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
        }
        gtk_window_destroy(windowPointer(window))
        guard page.title == "Hummingbird WebKit bootstrap" else {
            fatalError("Could not initialize WebKit")
        }
        try JSEngines.initializeDefaultRuntimeOnCurrentThread()
    } catch {
        fatalError("Could not initialize the shared JavaScript runtime: \(error)")
    }
    #else
    // Darwin uses the system JavaScriptCore framework. WebKitGTK is not
    // available there, so it does not need the shared-WTF bootstrap.
    do { try JSEngines.initializeDefaultRuntimeOnCurrentThread() }
    catch { fatalError("Could not initialize JavaScriptCore: \(error)") }
    #endif
    GTK4Backend().run(HummingbirdGTKApp.self)
}
