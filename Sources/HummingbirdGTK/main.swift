import HummingbirdKit
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
        WindowGroup("Hummingbird") { HummingbirdRoot() }
    }
}

MainActor.assumeIsolated {
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
        let page = WebPage()
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
