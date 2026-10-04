import HummingbirdKit
import SwiftOpenUI
import BackendGTK4
import WebKit
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
    GTK4Backend().run(HummingbirdGTKApp.self)
}
