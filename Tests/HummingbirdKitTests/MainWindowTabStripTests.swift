#if !canImport(SwiftUI)
import XCTest
import CGTK
import CGTKBridge
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4
@testable import HummingbirdKit

final class MainWindowTabStripTests: XCTestCase {
    @MainActor
    func testRenderedHomeTabIsPickableAndRestoresPinnedContent() async throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }

        let model = AppModel()
        model.openNewTab()
        let contentID = model.activeTabID
        let root = widgetFromOpaque(gtkRenderView(RootView().environment(model)))
        let window = gtk_window_new()!
        let win = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_child(win, root)
        let titlebar = try XCTUnwrap(findTitlebar(in: root))
        gtk_window_set_titlebar(win, titlebar)
        gtk_window_set_default_size(win, 1280, 720)
        gtk_widget_set_visible(window, 1)
        defer { gtk_window_destroy(win) }
        pump()

        let homeLabel = try XCTUnwrap(findLabel("Home", in: titlebar))
        let contentLabel = try XCTUnwrap(findLabel("New Tab", in: titlebar))
        let homeButton = try XCTUnwrap(ancestor(ofType: "GtkButton", from: homeLabel))
        let contentButton = try XCTUnwrap(ancestor(ofType: "GtkButton", from: contentLabel))
        let inactiveHeight = gtk_widget_get_height(homeButton)
        let activeHeight = gtk_widget_get_height(contentButton)
        let titlebarHeight = gtk_widget_get_height(titlebar)
        XCTAssertNotEqual(gtk_widget_get_sensitive(homeButton), 0)
        XCTAssertNotEqual(gtk_widget_get_can_target(homeButton), 0)

        var origin = graphene_point_t(x: 0, y: 0)
        var center = graphene_point_t()
        XCTAssertNotEqual(gtk_widget_compute_point(homeButton, titlebar, &origin, &center), 0)
        center.x += Float(gtk_widget_get_width(homeButton)) / 2
        center.y += Float(gtk_widget_get_height(homeButton)) / 2
        let picked = try XCTUnwrap(gtk_widget_pick(titlebar, Double(center.x), Double(center.y), GTK_PICK_DEFAULT))
        XCTAssertTrue(picked == homeButton || gtk_widget_is_ancestor(picked, homeButton) != 0,
                      "Home center picked \(typeName(picked)) outside its button")

        XCTAssertNotEqual(gtk_widget_activate(homeButton), 0)
        pump()
        XCTAssertEqual(model.activeTabID, model.pinnedTab.id)
        XCTAssertNotEqual(model.activeTabID, contentID)

        let updatedTitlebar = try XCTUnwrap(gtk_window_get_titlebar(win))
        let updatedHome = try XCTUnwrap(ancestor(ofType: "GtkButton", from: try XCTUnwrap(findLabel("Home", in: updatedTitlebar))))
        let updatedContent = try XCTUnwrap(ancestor(ofType: "GtkButton", from: try XCTUnwrap(findLabel("New Tab", in: updatedTitlebar))))
        XCTAssertEqual(gtk_widget_get_height(updatedHome), activeHeight,
                       "Home must use the same natural height as an active content tab")
        XCTAssertEqual(gtk_widget_get_height(updatedContent), inactiveHeight,
                       "content tabs must use the same natural height as inactive Home")
        XCTAssertEqual(gtk_widget_get_height(updatedTitlebar), titlebarHeight,
                       "switching to Home must not resize the CSD tab row")
    }

    private func pump() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            while g_main_context_pending(nil) != 0 { _ = g_main_context_iteration(nil, 0) }
            Thread.sleep(forTimeInterval: 0.005)
        }
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

    private func findLabel(_ text: String, in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if typeName(widget) == "GtkLabel", String(cString: gtk_label_get_text(OpaquePointer(widget))) == text {
            return widget
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findLabel(text, in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private func ancestor(ofType expected: String, from widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        var current: UnsafeMutablePointer<GtkWidget>? = widget
        while let node = current {
            if typeName(node) == expected { return node }
            current = gtk_widget_get_parent(node)
        }
        return nil
    }

    private func typeName(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        String(cString: g_type_name(gtk_swift_get_widget_type(widget)))
    }

}
#endif
