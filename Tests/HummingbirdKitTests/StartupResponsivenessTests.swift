#if canImport(BackendGTK4)
import XCTest
import Foundation
import CGTK
import CGTKBridge
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4

final class StartupResponsivenessTests: XCTestCase {
    @MainActor
    func testStartupDoesNotEvaluateUnselectedTabsAndRetainsVisitedPages() async throws {
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
        let originalHome = gtk_stack_get_child_by_name(OpaquePointer(stack), "home")
        let originalHomeBody = originalHome.flatMap { gtk_widget_get_first_child($0) }

        gtk_stack_set_visible_child_name(OpaquePointer(stack), "sources")
        XCTAssertGreaterThan(probe.evaluations["sources"] ?? 0, 0)
        XCTAssertEqual(probe.schemes["sources"], .dark,
                       "deferred construction must restore the tab's environment")
        XCTAssertNil(probe.evaluations["library"])
        let afterFirstVisit = probe.evaluations
        gtk_stack_set_visible_child_name(OpaquePointer(stack), "home")
        gtk_stack_set_visible_child_name(OpaquePointer(stack), "sources")
        XCTAssertEqual(probe.evaluations, afterFirstVisit, "visited pages must keep their widget/state lifetime")
        XCTAssertEqual(originalHome.flatMap { gtk_widget_get_first_child($0) }, originalHomeBody)
    }

    @MainActor
    func testBoundSelectionAndDuplicateTabNamesStillBuildOnlyTheSelectedPage() async throws {
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
        gtk_stack_set_visible_child(OpaquePointer(stack), first)
        XCTAssertEqual(selected, 0)
        XCTAssertGreaterThan(probe.evaluations["first"] ?? 0, 0)
        XCTAssertNil(probe.evaluations["second"])
    }

    private func findStack(_ widget: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkWidget>? {
        if String(cString: g_type_name(gtk_swift_get_widget_type(widget))) == "GtkStack" { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let stack = findStack(current) { return stack }
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
