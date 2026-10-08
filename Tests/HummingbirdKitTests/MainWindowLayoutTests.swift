#if !canImport(SwiftUI)
import XCTest
import CGTK
import CGTKBridge
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4
@testable import HummingbirdKit

final class MainWindowLayoutTests: XCTestCase {
    @MainActor
    func testMainContentFillsWindow() async throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }
        let root = widgetFromOpaque(gtkRenderView(HummingbirdRoot()))
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_halign(root, GTK_ALIGN_FILL)
        gtk_widget_set_valign(root, GTK_ALIGN_FILL)
        let window = gtk_window_new()!
        let win = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_child(win, root)
        let titlebar = try XCTUnwrap(findTitlebar(in: root))
        gtk_window_set_titlebar(win, titlebar)
        gtk_window_set_default_size(win, 1280, 720)
        gtk_widget_set_visible(window, 1)
        defer { gtk_window_destroy(win) }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(gtk_widget_get_height(root), 600)
        let content = try XCTUnwrap(gtk_widget_get_first_child(root))
        XCTAssertGreaterThan(gtk_widget_get_height(content), 600,
            "the rendered Hummingbird content must fill the GTK window")
    }

    private func findTitlebar(in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        let object = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self)
        if let data = g_object_get_data(object, "gtk-swift-window-titlebar") {
            return UnsafeMutableRawPointer(data).assumingMemoryBound(to: GtkWidget.self)
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findTitlebar(in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

}
#endif
