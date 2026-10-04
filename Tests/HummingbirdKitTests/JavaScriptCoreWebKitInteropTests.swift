#if canImport(BackendGTK4)
import XCTest
import Foundation
import HummingbirdKit
import SwiftOpenUI
import WebKit
@testable import BackendGTK4
import CGTK
import CGTKBridge

/// The leading name intentionally makes this process-global initialization
/// regression run before plugin tests create worker-thread JSC contexts.
final class AJavaScriptCoreWebKitInteropTests: XCTestCase {
    func testPluginJavaScriptCoreCanInitializeBeforeWebKit() async throws {
        try await MainActor.run {
            try JSEngines.initializeDefaultRuntimeOnCurrentThread()
        }

        try await Task.detached {
            let context = try JSEngines.default.makeContext { _, _, _ in "" }
            _ = try context.evaluate("1 + 1", name: "initialization-order-test")
            context.close()
        }.value

        try await MainActor.run {
            if gtk_is_initialized() == 0 { _ = gtk_init_check() }
            guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
            let widget = widgetFromOpaque(WebView(WebPage()).gtkCreateWidget())
            let window = gtk_window_new()!
            gtk_window_set_child(windowPointer(window), widget)
            gtk_widget_set_visible(window, 1)
            XCTAssertNotNil(gtk_window_get_child(windowPointer(window)))
            gtk_window_destroy(windowPointer(window))
        }
    }
}
#endif
