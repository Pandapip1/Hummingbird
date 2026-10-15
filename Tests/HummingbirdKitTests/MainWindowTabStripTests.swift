#if BACKEND_GTK
import XCTest
import CGTK
import CGTKBridge
import CAdwaita
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4
@testable import HummingbirdKit

final class MainWindowTabStripTests: XCTestCase {
    @MainActor
    func testRenderedSectionTabIsPickableAndAllTabsAreClosable() async throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }

        let model = makeTestAppModel()
        model.openInNewTab(.search, title: "Search")
        model.activeTab.push(.settings, title: "Settings")
        let contentID = model.activeTabID
        let root = widgetFromOpaque(gtkRenderView(RootView().environment(model)))
        let window = gtk_window_new()!
        let win = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        let windowContent = gtkAdwaitaWindowContent(root)
        gtk_window_set_child(win, windowContent)
        gtk_window_set_default_size(win, 1280, 720)
        gtk_widget_set_visible(window, 1)
        defer { gtk_window_destroy(win) }
        pump()

        let overview = try XCTUnwrap(findFirst(ofType: "AdwTabOverview", in: root))
        XCTAssertEqual(gtk_window_get_child(win), windowContent,
                       "the structural root host must remain the window content")
        let toolbarView = try XCTUnwrap(findFirst(ofType: "AdwToolbarView", in: overview))
        XCTAssertNotEqual(swift_adw_toolbar_view_get_top_bar_raised(toolbarView), 0,
                          "browser chrome must use libadwaita's raised tab-toolbar treatment")
        let tabBar = try XCTUnwrap(findFirst(ofType: "AdwTabBar", in: toolbarView))
        let overviewButton = try XCTUnwrap(findFirst(ofType: "AdwTabButton", in: toolbarView))
        let tabControlGroup = try XCTUnwrap(gtk_widget_get_parent(overviewButton))
        XCTAssertNotEqual(gtk_widget_has_css_class(tabControlGroup, "linked"), 0,
                          "new-tab and overview controls must be one joined native control")
        XCTAssertNotNil(findFirst(ofType: "GtkMenuButton", in: tabControlGroup),
                        "the joined new-tab control must present destination choices")
        XCTAssertNil(findFirst(ofType: "AdwViewSwitcherSidebar", in: root),
                     "top-level sections must no longer render a nested TabView sidebar")
        let tabView = try XCTUnwrap(swift_adw_tab_bar_get_view(tabBar))
        XCTAssertEqual(swift_adw_tab_view_get_n_pages(tabView), 2)
        let homePage = try XCTUnwrap(swift_adw_tab_view_get_nth_page(tabView, 0))
        let contentPage = try XCTUnwrap(swift_adw_tab_view_get_nth_page(tabView, 1))
        XCTAssertEqual(swift_adw_tab_page_get_pinned(homePage), 0)
        XCTAssertEqual(swift_adw_tab_page_get_pinned(contentPage), 0)
        XCTAssertEqual(String(cString: try XCTUnwrap(swift_adw_tab_page_get_title(homePage))), "Home")
        XCTAssertEqual(String(cString: try XCTUnwrap(swift_adw_tab_page_get_title(contentPage))), "Settings")
        let selectedContent = try XCTUnwrap(swift_adw_tab_page_get_child(contentPage))
        XCTAssertNil(findFirst(ofType: "AdwViewSwitcherSidebar", in: selectedContent))
        let contentButtonCenter = try center(of: selectedContent, in: root)
        let pickedContent = try XCTUnwrap(
            gtk_widget_pick(root, contentButtonCenter.x, contentButtonCenter.y, GTK_PICK_DEFAULT),
            "selected page must be reachable through the full root hierarchy")
        XCTAssertTrue(isSelfOrDescendant(pickedContent, of: selectedContent),
                      "window overlays must not intercept selected-page interactions")
        XCTAssertEqual(swift_adw_tab_view_get_selected_page(tabView), contentPage)
        XCTAssertNotNil(ancestor(ofType: "GtkHeaderBar", from: overviewButton),
                        "the overview button belongs in the embedded top row with the window controls")
        XCTAssertEqual(gtk_widget_activate(overviewButton), 1)
        pump()
        XCTAssertEqual(swift_adw_tab_overview_get_open(overview), 1,
                       "activating AdwTabButton must open the native tab overview")
        swift_adw_tab_overview_set_open(overview, 0)
        if let nestedSlot = findNestedTitlebarSlot(in: toolbarView) {
            XCTAssertNil(gtk_widget_get_first_child(nestedSlot),
                         "the page title must not create a row underneath the browser tab bar")
        }
        XCTAssertNotNil(ancestor(ofType: "AdwToolbarView", from: tabBar),
                        "AdwTabBar must be installed as an AdwToolbarView row")
        XCTAssertNil(ancestor(ofType: "GtkHeaderBar", from: tabBar),
                     "AdwTabBar must not receive a second header-bar treatment")
        var historyButtons = try XCTUnwrap(findHistoryButtons(in: toolbarView))
        XCTAssertNotEqual(gtk_widget_get_sensitive(historyButtons.back), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(historyButtons.forward), 0)
        XCTAssertEqual(gtk_widget_activate(historyButtons.back), 1)
        pump()
        XCTAssertEqual(model.activeTab.current, .search)
        historyButtons = try XCTUnwrap(findHistoryButtons(in: overview))
        XCTAssertEqual(gtk_widget_get_sensitive(historyButtons.back), 0)
        XCTAssertNotEqual(gtk_widget_get_sensitive(historyButtons.forward), 0)
        XCTAssertEqual(gtk_widget_activate(historyButtons.forward), 1)
        pump()
        XCTAssertEqual(model.activeTab.current, .settings)
        historyButtons = try XCTUnwrap(findHistoryButtons(in: overview))
        XCTAssertNotEqual(gtk_widget_get_sensitive(historyButtons.back), 0)
        XCTAssertEqual(gtk_widget_get_sensitive(historyButtons.forward), 0)
        let toolbarHeight = gtk_widget_get_height(toolbarView)
        swift_adw_tab_view_set_selected_page(tabView, homePage)
        pump()
        XCTAssertEqual(model.activeTabID, homePageID(model))
        XCTAssertNotEqual(model.activeTabID, contentID)

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
        XCTAssertEqual(model.contentTabs.count, 1, "AdwTabView close requests must reach AppModel")

    }

    @MainActor
    func testNewTabControlPresentsDestinationsWithoutCreatingBlankTab() throws {
        try TestDisplaySession.start()
        guard gtk_init_check() != 0 else { throw XCTSkip("GTK display required") }

        let model = makeTestAppModel()
        let root = widgetFromOpaque(gtkRenderView(RootView().environment(model)))
        let window = gtk_window_new()!
        let win = UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_child(win, gtkAdwaitaWindowContent(root))
        gtk_window_set_default_size(win, 1280, 720)
        gtk_widget_set_visible(window, 1)
        defer { gtk_window_destroy(win) }
        pump()
        let overviewButton = try XCTUnwrap(findFirst(ofType: "AdwTabButton", in: root))
        let group = try XCTUnwrap(gtk_widget_get_parent(overviewButton))
        let newTabButton = try XCTUnwrap(findFirst(ofType: "GtkMenuButton", in: group))
        XCTAssertEqual(typeName(newTabButton), "GtkMenuButton")
        let count = model.contentTabs.count

        let popover = try XCTUnwrap(findFirst(ofType: "GtkPopover", in: newTabButton))
        gtk_swift_popover_popup(popover)
        pump()
        XCTAssertNotEqual(gtk_widget_get_visible(popover), 0)
        XCTAssertEqual(model.contentTabs.count, count,
                       "presenting the destination menu must not create a blank tab")
        XCTAssertTrue(model.contentTabs.allSatisfy { $0.current != nil })
    }

    @MainActor
    private func homePageID(_ model: AppModel) -> UUID {
        model.contentTabs.first { $0.current == .home }!.id
    }

    private func pump() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            while g_main_context_pending(nil) != 0 { _ = g_main_context_iteration(nil, 0) }
            Thread.sleep(forTimeInterval: 0.005)
        }
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

    private func findHistoryButtons(
        in widget: UnsafeMutablePointer<GtkWidget>
    ) -> (back: UnsafeMutablePointer<GtkWidget>, forward: UnsafeMutablePointer<GtkWidget>)? {
        if gtk_widget_has_css_class(widget, "linked") != 0,
           findFirst(ofType: "AdwTabButton", in: widget) == nil,
           let backRoot = gtk_widget_get_first_child(widget),
           let forwardRoot = gtk_widget_get_next_sibling(backRoot),
           gtk_widget_get_next_sibling(forwardRoot) == nil,
           let back = findFirst(ofType: "GtkButton", in: backRoot),
           let forward = findFirst(ofType: "GtkButton", in: forwardRoot) {
            return (back, forward)
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let buttons = findHistoryButtons(in: current) { return buttons }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private func center(
        of child: UnsafeMutablePointer<GtkWidget>,
        in root: UnsafeMutablePointer<GtkWidget>
    ) throws -> (x: Double, y: Double) {
        var source = graphene_point_t()
        graphene_point_init(&source, Float(gtk_widget_get_width(child)) / 2,
                            Float(gtk_widget_get_height(child)) / 2)
        var target = graphene_point_t()
        guard gtk_widget_compute_point(child, root, &source, &target) != 0 else {
            throw XCTSkip("could not resolve control coordinates")
        }
        return (Double(target.x), Double(target.y))
    }

    private func isSelfOrDescendant(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        of ancestor: UnsafeMutablePointer<GtkWidget>
    ) -> Bool {
        var current: UnsafeMutablePointer<GtkWidget>? = widget
        while let node = current {
            if node == ancestor { return true }
            current = gtk_widget_get_parent(node)
        }
        return false
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
