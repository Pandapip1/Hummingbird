#if canImport(BackendGTK4)
import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HummingbirdKit
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import WebKit
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
            let widget = widgetFromOpaque(gtkRenderView(
                WebView(session.page)
                    .frame(
                        minWidth: 720, maxWidth: .infinity,
                        minHeight: 540, maxHeight: .infinity
                    )
            ))
            let window = gtk_window_new()!
            gtk_window_set_child(windowPointer(window), widget)
            gtk_widget_set_visible(window, 1)

            let deadline = Date().addingTimeInterval(10)
            while session.page.title != "Debug authentication rendered", Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
            }
            XCTAssertEqual(session.page.title, "Debug authentication rendered")
            XCTAssertGreaterThanOrEqual(gtk_widget_get_width(widget), 720)
            XCTAssertGreaterThanOrEqual(gtk_widget_get_height(widget), 540)
            let webView = try XCTUnwrap(gtk_widget_get_first_child(widget))
            XCTAssertGreaterThanOrEqual(gtk_widget_get_width(webView), 720)
            XCTAssertGreaterThanOrEqual(gtk_widget_get_height(webView), 540)
            session.cancel()
            gtk_window_destroy(windowPointer(window))
        }
    }

    @MainActor
    func testDebugAuthenticationServerRendersAndSetsHTTPOnlyCookie() async throws {
        guard let rawBase = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_AUTH_URL"],
              let baseURL = URL(string: rawBase) else {
            throw XCTSkip("set HUMMINGBIRD_DEBUG_AUTH_URL to exercise the live debug login server")
        }
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        let bootstrapPage = WebPage()
        let bootstrapWidget = widgetFromOpaque(WebView(bootstrapPage).gtkCreateWidget())
        let bootstrapWindow = gtk_window_new()!
        gtk_window_set_child(windowPointer(bootstrapWindow), bootstrapWidget)
        gtk_widget_set_visible(bootstrapWindow, 1)
        bootstrapPage.load(html: "<title>WebKit bootstrap</title>")
        var deadline = Date().addingTimeInterval(10)
        while bootstrapPage.title != "WebKit bootstrap", Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            await Task.yield()
        }
        XCTAssertEqual(bootstrapPage.title, "WebKit bootstrap")
        gtk_window_destroy(windowPointer(bootstrapWindow))
        try JSEngines.initializeDefaultRuntimeOnCurrentThread()
        try await Task.detached {
            let context = try JSEngines.default.makeContext { _, _, _ in "" }
            _ = try context.evaluate("1 + 1", name: "live-web-auth-order-test")
            context.close()
        }.value
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
        let spec = WebAuthSpec(
            title: "Debug sign in",
            startURL: baseURL.appendingPathComponent("login.html"),
            completionURL: baseURL.appendingPathComponent("login-complete").absoluteString,
            cookiesToFind: ["debug_session"],
            hostAllowed: { $0 == "127.0.0.1" }
        )
        var completedAuth: SourceAuth?
        let session = WebAuthSession(spec: spec) { completedAuth = $0 }
        session.start()
        let page = session.page
        let widget = widgetFromOpaque(WebView(page).gtkCreateWidget())
        let window = gtk_window_new()!
        gtk_window_set_child(windowPointer(window), widget)
        gtk_widget_set_visible(window, 1)

        deadline = Date().addingTimeInterval(10)
        while page.title != "Hummingbird debug sign in", Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            await Task.yield()
        }
        XCTAssertEqual(page.title, "Hummingbird debug sign in")

        page.load(baseURL.appendingPathComponent("login-complete"))
        deadline = Date().addingTimeInterval(10)
        while completedAuth == nil, Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completedAuth?.cookieMap[".127.0.0.1"]?["debug_session"], "authenticated")
        gtk_window_destroy(windowPointer(window))
    }
}
#endif
