#if canImport(BackendGTK4) && BACKEND_GTK_WEBKIT
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
            try TestDisplaySession.start()
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
            try TestDisplaySession.start()
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
                        minWidth: 320, maxWidth: .infinity,
                        minHeight: 320, maxHeight: .infinity
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
            XCTAssertGreaterThanOrEqual(gtk_widget_get_width(widget), 320)
            XCTAssertGreaterThanOrEqual(gtk_widget_get_height(widget), 320)
            let renderedContent = try XCTUnwrap(gtk_widget_get_first_child(widget))
            XCTAssertGreaterThanOrEqual(gtk_widget_get_width(renderedContent), 320)
            XCTAssertGreaterThanOrEqual(gtk_widget_get_height(renderedContent), 320)
            session.cancel()
            gtk_window_destroy(windowPointer(window))
        }
    }

    @MainActor
    func testBackgroundAuthorizationCompletesWithoutPageNavigation() async throws {
        try TestDisplaySession.start()
        guard let rawBase = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_AUTH_URL"],
              let baseURL = URL(string: rawBase) else {
            throw XCTSkip("set HUMMINGBIRD_DEBUG_AUTH_URL to exercise the live debug login server")
        }
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }

        for transport in ["fetch", "xhr", "frame-fetch", "frame-xhr", "fetch-relative", "xhr-relative"] {
            let loginURL = baseURL.appendingPathComponent("login.html")
            var authOrigin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            if transport.hasPrefix("frame-") { authOrigin.host = "localhost" }
            let authBase = authOrigin.url!
            let authHost = authOrigin.host!
            let spec = WebAuthSpec(
                title: "Background authorization",
                startURL: loginURL,
                completionURL: authBase.appendingPathComponent("api/authorization/").absoluteString,
                headersToFind: ["Authorization"],
                // Third-party iframe cookies may be blocked by WebKit. The
                // iframe cases exercise header/completion forwarding; the
                // top-level cases additionally exercise HTTP-only cookies.
                cookiesToFind: transport.hasPrefix("frame-") ? [] : ["debug_session"],
                hostAllowed: { $0 == authHost }
            )
            var completedAuth: SourceAuth?
            let session = WebAuthSession(spec: spec) { completedAuth = $0 }
            let window = gtk_window_new()!
            gtk_window_set_child(windowPointer(window), widgetFromOpaque(WebView(session.page).gtkCreateWidget()))
            gtk_widget_set_visible(window, 1)
            session.start()
            defer {
                session.stop()
                gtk_window_destroy(windowPointer(window))
            }

            var deadline = Date().addingTimeInterval(10)
            while session.page.title != "Hummingbird debug sign in", Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(session.page.title, "Hummingbird debug sign in")
            XCTAssertFalse(session.credentialsReady)
            let request = Task {
                let script = transport.hasPrefix("frame-") ? """
                    const frame = document.createElement('iframe');
                    frame.src = frameURL;
                    document.body.appendChild(frame);
                    """ : transport.hasSuffix("-relative") ? """
                    const base = document.createElement('base');
                    base.href = '/api/';
                    document.head.appendChild(base);
                    if (transport === 'fetch-relative') {
                      fetch('authorization/', {headers: {Authorization: 'Bearer debug-token'}});
                    } else {
                      const request = new XMLHttpRequest();
                      request.open('GET', 'authorization/');
                      request.setRequestHeader('Authorization', 'Bearer debug-token');
                      request.send();
                    }
                    base.href = '/changed/';
                    history.replaceState({}, '', '/changed/login.html');
                    """ : transport == "fetch" ? """
                    document.getElementById('sign-in').click();
                    """ : """
                    const request = new XMLHttpRequest();
                    request.open('GET', '/api/authorization/');
                    request.setRequestHeader('Authorization', 'Bearer debug-token');
                    request.send();
                    """
                return try await session.page.callJavaScript(script, arguments: [
                    "transport": transport,
                    "frameURL": authBase.appendingPathComponent("login-frame.html").absoluteString +
                        "?transport=" + (transport == "frame-xhr" ? "xhr" : "fetch")
                ])
            }
            deadline = Date().addingTimeInterval(10)
            while !session.credentialsReady, Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try await request.value
            XCTAssertTrue(session.credentialsReady, "\(transport) completion URL must be detected")
            if !transport.hasSuffix("-relative") {
                XCTAssertEqual(session.page.url, loginURL, "completion must not require navigation")
            }
            XCTAssertNil(completedAuth, "readiness must wait for explicit Done")

            let finish = Task { await session.finish() }
            deadline = Date().addingTimeInterval(10)
            while completedAuth == nil, Date() < deadline {
                _ = g_main_context_iteration(nil, 0)
                try await Task.sleep(for: .milliseconds(10))
            }
            await finish.value
            if !transport.hasPrefix("frame-") {
                XCTAssertEqual(completedAuth?.cookieMap["." + authHost]?["debug_session"], "authenticated")
            }
            XCTAssertNil(completedAuth?.cookieMap["." + authHost]?["unrelated_cookie"])
            XCTAssertEqual(completedAuth?.headers[authHost]?["authorization"], "Bearer debug-token")
        }
    }

    @MainActor
    func testFailedBackgroundAuthorizationDoesNotBecomeReady() async throws {
        guard let rawBase = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_AUTH_URL"],
              let baseURL = URL(string: rawBase) else {
            throw XCTSkip("set HUMMINGBIRD_DEBUG_AUTH_URL to exercise the live debug login server")
        }
        try TestDisplaySession.start()
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }

        for transport in ["fetch", "xhr"] {
            for result in ["unauthorized", "network-error", "stale-then-headerless"] {
                let spec = WebAuthSpec(
                    title: "Failed authorization",
                    startURL: baseURL.appendingPathComponent("login.html"),
                    completionURL: baseURL.appendingPathComponent("api/authorization/").absoluteString + "?*",
                    headersToFind: ["Authorization"], cookiesToFind: ["debug_session"],
                    hostAllowed: { $0 == "127.0.0.1" }
                )
                var captured: SourceAuth?
                let session = WebAuthSession(spec: spec) { captured = $0 }
                let window = gtk_window_new()!
                gtk_window_set_child(windowPointer(window), widgetFromOpaque(WebView(session.page).gtkCreateWidget()))
                gtk_widget_set_visible(window, 1)
                session.start()
                defer { session.stop(); gtk_window_destroy(windowPointer(window)) }
                var deadline = Date().addingTimeInterval(10)
                while session.page.title != "Hummingbird debug sign in", Date() < deadline {
                    _ = g_main_context_iteration(nil, 0)
                    try await Task.sleep(for: .milliseconds(10))
                }
                let attempt = Task {
                    try await session.page.callJavaScript("""
                        // Seed the required cookie first, so completion status
                        // is the only missing readiness condition.
                        fetch('/login-complete').then(() => {
                          const done = () => { document.title = 'Attempt finished'; };
                          const attempt = (result, authenticated) => {
                            const url = '/api/authorization/?result=' + result;
                            if (transport === 'fetch') {
                              return fetch(url, {headers: authenticated ? {Authorization: 'Bearer debug-token'} : {}})
                                .catch(() => {});
                            }
                            return new Promise(resolve => {
                              const request = new XMLHttpRequest();
                              request.open('GET', url);
                              if (authenticated) request.setRequestHeader('Authorization', 'Bearer debug-token');
                              request.addEventListener('loadend', resolve);
                              request.send();
                            });
                          };
                          attempt(result === 'stale-then-headerless' ? 'unauthorized' : result, true)
                            .then(() => result === 'stale-then-headerless' ? attempt('headerless', false) : undefined)
                            .then(done);
                        });
                        """, arguments: ["transport": transport, "result": result])
                }
                deadline = Date().addingTimeInterval(10)
                while session.page.title != "Attempt finished", Date() < deadline {
                    _ = g_main_context_iteration(nil, 0)
                    try await Task.sleep(for: .milliseconds(10))
                }
                _ = try await attempt.value
                XCTAssertEqual(session.page.title, "Attempt finished")
                deadline = Date().addingTimeInterval(0.75)
                while Date() < deadline {
                    _ = g_main_context_iteration(nil, 0)
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(session.credentialsReady, "\(transport) \(result) must not complete login")
                XCTAssertNil(captured)
                let finish = Task { await session.finish() }
                deadline = Date().addingTimeInterval(10)
                while captured == nil, Date() < deadline {
                    _ = g_main_context_iteration(nil, 0)
                    try await Task.sleep(for: .milliseconds(10))
                }
                await finish.value
                XCTAssertEqual(captured?.cookieMap[".127.0.0.1"]?["debug_session"], "authenticated")
                XCTAssertNil(captured?.headers["127.0.0.1"]?["authorization"], "failed requests must not supply credentials")
            }
        }
    }

    @MainActor
    func testDebugAuthenticationServerRendersAndSetsHTTPOnlyCookie() async throws {
        guard let rawBase = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_AUTH_URL"],
              let baseURL = URL(string: rawBase) else {
            throw XCTSkip("set HUMMINGBIRD_DEBUG_AUTH_URL to exercise the live debug login server")
        }
        try TestDisplaySession.start()
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
        try TestDisplaySession.start()
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
        while !session.credentialsReady, Date() < deadline {
            _ = g_main_context_iteration(nil, 0)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.credentialsReady)
        XCTAssertNil(completedAuth, "detecting credentials must wait for explicit confirmation")
        await session.finish()
        XCTAssertEqual(completedAuth?.cookieMap[".127.0.0.1"]?["debug_session"], "authenticated")
        gtk_window_destroy(windowPointer(window))
    }
}
#endif
