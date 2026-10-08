#if canImport(BackendGTK4)
import XCTest
import Foundation
import CGTK
import CGTKBridge
import CAdwaita
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4

final class StartupResponsivenessTests: XCTestCase {
    @MainActor
    func testPinnedTabsUseNativeAdaptiveSidebar() async throws {
        try TestDisplaySession.start()
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        try XCTSkipUnless(gtk_is_initialized() != 0, "no GTK display")
        let root = widgetFromOpaque(gtkRenderView(
            TabView {
                Tab("Home") { Text("Home") }
                Tab("Library") { Text("Library") }
            }
            .tabViewStyle(.sidebarAdaptable)
        ))
        g_object_ref_sink(gpointer(root))
        defer { g_object_unref(gpointer(root)) }
        XCTAssertNotNil(findWidget(ofType: "AdwViewSwitcherSidebar", in: root))
        XCTAssertNil(findWidget(ofType: "AdwViewSwitcher", in: root),
                     "sidebarAdaptable must not fall back to the default tab switcher")
    }

    @MainActor
    func testStartupDoesNotEvaluateUnselectedTabsAndRetainsVisitedPages() async throws {
        try TestDisplaySession.start()
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        try XCTSkipUnless(gtk_is_initialized() != 0, "no GTK display")
        let probe = StartupTabProbe()
        let tabs = TabView(initialTab: 1) {
            Tab("Library", id: "library") { StartupTabBody(probe: probe, name: "library") }
            Tab("Home", id: "home") { StartupTabBody(probe: probe, name: "home") }
            Tab("Sources", id: "sources") { StartupTabBody(probe: probe, name: "sources") }
        }.environment(\.colorScheme, .dark)
        let root = widgetFromOpaque(gtkRenderView(tabs))
        g_object_ref_sink(gpointer(root))
        defer { g_object_unref(gpointer(root)) }
        let stack = try XCTUnwrap(findStack(root))
        XCTAssertNil(probe.evaluations["library"], "unvisited work must not delay the first frame")
        XCTAssertNil(probe.evaluations["sources"])
        XCTAssertGreaterThan(probe.evaluations["home"] ?? 0, 0)
        XCTAssertEqual(probe.schemes["home"], .dark)
        let originalHome = "home".withCString { swift_adw_view_stack_get_child_by_name(stack, $0) }
        let originalHomeBody = originalHome.flatMap { gtk_widget_get_first_child($0) }

        "sources".withCString { swift_adw_view_stack_set_visible_child_name(stack, $0) }
        XCTAssertGreaterThan(probe.evaluations["sources"] ?? 0, 0)
        XCTAssertEqual(probe.schemes["sources"], .dark,
                       "deferred construction must restore the tab's environment")
        XCTAssertNil(probe.evaluations["library"])
        let afterFirstVisit = probe.evaluations
        "home".withCString { swift_adw_view_stack_set_visible_child_name(stack, $0) }
        "sources".withCString { swift_adw_view_stack_set_visible_child_name(stack, $0) }
        XCTAssertEqual(probe.evaluations, afterFirstVisit, "visited pages must keep their widget/state lifetime")
        XCTAssertEqual(originalHome.flatMap { gtk_widget_get_first_child($0) }, originalHomeBody)
    }

    @MainActor
    func testBoundSelectionAndDuplicateTabNamesStillBuildOnlyTheSelectedPage() async throws {
        try TestDisplaySession.start()
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        try XCTSkipUnless(gtk_is_initialized() != 0, "no GTK display")
        let probe = StartupTabProbe()
        var selected = 2
        let root = widgetFromOpaque(gtkRenderView(TabView(selection: Binding(
            get: { selected }, set: { selected = $0 }
        )) {
            StartupTabBody(probe: probe, name: "first").tabItem { Text("Page") }.tag(0)
            StartupTabBody(probe: probe, name: "second").tabItem { Text("Page") }.tag(1)
            StartupTabBody(probe: probe, name: "third").tabItem { Text("Page") }.tag(2)
        }))
        g_object_ref_sink(gpointer(root))
        defer { g_object_unref(gpointer(root)) }
        let stack = try XCTUnwrap(findStack(root))
        XCTAssertNil(probe.evaluations["first"])
        XCTAssertNil(probe.evaluations["second"])
        XCTAssertGreaterThan(probe.evaluations["third"] ?? 0, 0)
        // Switch by widget, independent of the generated duplicate-title IDs.
        let first = try XCTUnwrap(gtk_widget_get_first_child(stack))
        swift_adw_view_stack_set_visible_child(stack, first)
        XCTAssertEqual(selected, 0)
        XCTAssertGreaterThan(probe.evaluations["first"] ?? 0, 0)
        XCTAssertNil(probe.evaluations["second"])
    }

    private func findStack(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if String(cString: g_type_name(gtk_swift_get_widget_type(widget))) == "AdwViewStack" { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let stack = findStack(current) { return stack }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }

    private func findWidget(ofType expected: String, in widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if String(cString: g_type_name(gtk_swift_get_widget_type(widget))) == expected { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findWidget(ofType: expected, in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
}

private final class StartupTabProbe {
    var evaluations: [String: Int] = [:]
    var schemes: [String: ColorScheme] = [:]
}

private struct StartupTabBody: View {
    let probe: StartupTabProbe
    let name: String
    @Environment(\.colorScheme) private var scheme
    @State private var clicks = 0

    var body: some View {
        probe.evaluations[name, default: 0] += 1
        probe.schemes[name] = scheme
        return Button("\(name) \(clicks)") { clicks += 1 }
    }
}
#endif
