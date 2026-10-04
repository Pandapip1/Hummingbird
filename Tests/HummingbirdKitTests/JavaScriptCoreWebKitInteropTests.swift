#if canImport(BackendGTK4)
import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HummingbirdKit
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

    func testAuthenticationPageIsLoadedBeforeWebViewAttachment() async throws {
        try await MainActor.run {
            if gtk_is_initialized() == 0 { _ = gtk_init_check() }
            guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
            let spec = WebAuthSpec(
                title: "Debug sign in",
                startURL: URL(string: "http://127.0.0.1:8742/login.html"),
                html: "<html><head><title>Debug authentication rendered</title></head><body><h1>Sign in</h1></body></html>",
                hostAllowed: { $0 == "127.0.0.1" }
            )
            let session = WebAuthSession(spec: spec) { _ in }
            let widget = widgetFromOpaque(WebView(session.page).gtkCreateWidget())
            let window = gtk_window_new()!
            gtk_window_set_child(windowPointer(window), widget)
            gtk_widget_set_visible(window, 1)

            let deadline = Date().addingTimeInterval(10)
            while session.page.title != "Debug authentication rendered", Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            XCTAssertEqual(session.page.title, "Debug authentication rendered")
            XCTAssertGreaterThan(gtk_widget_get_width(widget), 0)
            XCTAssertGreaterThan(gtk_widget_get_height(widget), 0)
            gtk_window_destroy(windowPointer(window))
        }
    }

    func testDebugAuthenticationServerRendersAndSetsHTTPOnlyCookie() async throws {
        guard let rawBase = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_AUTH_URL"],
              let baseURL = URL(string: rawBase) else {
            throw XCTSkip("set HUMMINGBIRD_DEBUG_AUTH_URL to exercise the live debug login server")
        }
        try await MainActor.run {
            if gtk_is_initialized() == 0 { _ = gtk_init_check() }
            guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
            let store = WKWebsiteDataStore.nonPersistent()
            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration)
            page.load(baseURL.appendingPathComponent("login.html"))
            let widget = widgetFromOpaque(WebView(page).gtkCreateWidget())
            let window = gtk_window_new()!
            gtk_window_set_child(windowPointer(window), widget)
            gtk_widget_set_visible(window, 1)

            var deadline = Date().addingTimeInterval(10)
            while page.title != "Hummingbird debug sign in", Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            XCTAssertEqual(page.title, "Hummingbird debug sign in")

            page.load(baseURL.appendingPathComponent("login-complete"))
            deadline = Date().addingTimeInterval(10)
            while page.title != "Debug sign-in complete", Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            var cookies: [HTTPCookie]?
            store.httpCookieStore.getAllCookies { cookies = $0 }
            deadline = Date().addingTimeInterval(10)
            while cookies == nil, Date() < deadline { _ = g_main_context_iteration(nil, 0) }
            XCTAssertEqual(cookies?.first(where: { $0.name == "debug_session" })?.value, "authenticated")
            gtk_window_destroy(windowPointer(window))
        }
    }
}
#endif
