#if !canImport(SwiftUI)
import XCTest
import CGTK
import CGTKBridge
import CAdwaita
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
        XCTAssertNil(findTitlebar(in: root),
                     "the WindowGroup host must not discover and detach chrome from AdwTabOverview")
        let window = gtk_window_new()!
        let win = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_child(win, root)
        gtk_window_set_default_size(win, 1280, 720)
        gtk_widget_set_visible(window, 1)
        defer { gtk_window_destroy(win) }
        pump()

        let overview = try XCTUnwrap(findFirst(ofType: "AdwTabOverview", in: root))
        XCTAssertEqual(gtk_window_get_child(win), overview,
                       "AdwTabOverview must be the GtkWindow's top-level child")
        XCTAssertNil(gtk_window_get_titlebar(win),
                     "AdwTabOverview owns the window chrome; GtkWindow must not detach a titlebar")
        let toolbarView = try XCTUnwrap(findFirst(ofType: "AdwToolbarView", in: overview))
        let tabBar = try XCTUnwrap(findFirst(ofType: "AdwTabBar", in: toolbarView))
        let overviewButton = try XCTUnwrap(findFirst(ofType: "AdwTabButton", in: toolbarView))
        XCTAssertNotNil(findFirst(ofType: "AdwViewSwitcherSidebar", in: root),
                        "the pinned app sections use SwiftUI's sidebarAdaptable tab style")
        let tabView = try XCTUnwrap(swift_adw_tab_bar_get_view(tabBar))
        XCTAssertEqual(swift_adw_tab_view_get_n_pages(tabView), 2)
        let homePage = try XCTUnwrap(swift_adw_tab_view_get_nth_page(tabView, 0))
        let contentPage = try XCTUnwrap(swift_adw_tab_view_get_nth_page(tabView, 1))
        XCTAssertNotEqual(swift_adw_tab_page_get_pinned(homePage), 0)
        XCTAssertEqual(swift_adw_tab_page_get_pinned(contentPage), 0)
        XCTAssertEqual(String(cString: try XCTUnwrap(swift_adw_tab_page_get_title(homePage))), "Home")
        XCTAssertEqual(String(cString: try XCTUnwrap(swift_adw_tab_page_get_title(contentPage))), "New Tab")
        XCTAssertNotNil(findFirst(ofType: "AdwViewSwitcherSidebar",
                                  in: try XCTUnwrap(swift_adw_tab_page_get_child(contentPage))),
                        "the selected overview card must own the rendered tab content")
        XCTAssertEqual(swift_adw_tab_view_get_selected_page(tabView), contentPage)
        let principalRow = try XCTUnwrap(ancestor(withCSSClass: "toolbar", from: tabBar))
        let header = try XCTUnwrap(findFirst(ofType: "GtkHeaderBar", in: toolbarView))
        XCTAssertNotNil(ancestor(ofType: "GtkHeaderBar", from: overviewButton),
                        "the overview button belongs in the embedded top row with the window controls")
        XCTAssertEqual(gtk_widget_activate(overviewButton), 1)
        pump()
        XCTAssertEqual(swift_adw_tab_overview_get_open(overview), 1,
                       "activating AdwTabButton must open the native tab overview")
        swift_adw_tab_overview_set_open(overview, 0)
        XCTAssertNotNil(findLabel("New Tab", in: header),
                        "the selected tab title belongs in the native window header")
        XCTAssertEqual(String(cString: try XCTUnwrap(gtk_window_get_title(win))), "New Tab")
        if let nestedSlot = findNestedTitlebarSlot(in: toolbarView) {
            XCTAssertNil(gtk_widget_get_first_child(nestedSlot),
                         "the page title must not create a row underneath the browser tab bar")
        }
        XCTAssertGreaterThanOrEqual(gtk_widget_get_height(principalRow), gtk_widget_get_height(header),
                                    "the native AdwTabBar must retain at least header-bar vertical rhythm")
        let toolbarHeight = gtk_widget_get_height(toolbarView)
        swift_adw_tab_view_set_selected_page(tabView, homePage)
        pump()
        XCTAssertEqual(model.activeTabID, model.pinnedTab.id)
        XCTAssertNotEqual(model.activeTabID, contentID)
        XCTAssertEqual(String(cString: try XCTUnwrap(gtk_window_get_title(win))), "Home")

        let updatedToolbar = try XCTUnwrap(findFirst(ofType: "AdwToolbarView", in: overview))
        if let nestedSlot = findNestedTitlebarSlot(in: updatedToolbar) {
            XCTAssertEqual(gtk_widget_get_visible(nestedSlot), 0,
                           "Home's hidden Back button must not leave a blank titlebar row")
            XCTAssertEqual(gtk_widget_get_height(nestedSlot), 0,
                           "the empty nested navigation row must consume no vertical space")
        }
        let updatedBar = try XCTUnwrap(findFirst(ofType: "AdwTabBar", in: updatedToolbar))
        let updatedTabView = try XCTUnwrap(swift_adw_tab_bar_get_view(updatedBar))
        XCTAssertEqual(swift_adw_tab_view_get_selected_page(updatedTabView),
                       swift_adw_tab_view_get_nth_page(updatedTabView, 0))
        XCTAssertEqual(gtk_widget_get_height(updatedToolbar), toolbarHeight,
                       "switching to Home must not resize the overview's window contents")
        let updatedContentPage = try XCTUnwrap(swift_adw_tab_view_get_nth_page(updatedTabView, 1))
        swift_adw_tab_view_close_page(updatedTabView, updatedContentPage)
        pump()
        XCTAssertTrue(model.contentTabs.isEmpty, "AdwTabView close requests must reach AppModel")
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

    private func ancestor(withCSSClass name: String, from widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        var current: UnsafeMutablePointer<GtkWidget>? = widget
        while let node = current {
            if gtk_widget_has_css_class(node, name) != 0 { return node }
            current = gtk_widget_get_parent(node)
        }
        return nil
    }

    private func findFirst(ofType expected: String, in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if typeName(widget) == expected { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findFirst(ofType: expected, in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private func findNestedTitlebarSlot(in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        let object = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self)
        if g_object_get_data(object, "gtk-swift-is-nested-titlebar-slot") != nil { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findNestedTitlebarSlot(in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private func typeName(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        String(cString: g_type_name(gtk_swift_get_widget_type(widget)))
    }

}
#endif
