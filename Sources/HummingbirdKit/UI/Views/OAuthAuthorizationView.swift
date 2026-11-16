import Foundation
import SwiftOpenUI
#if canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))
private typealias OAuthWebPage = SwiftOpenUI.WebPage
private typealias OAuthWebView = SwiftOpenUI.WebView
#elseif BACKEND_GTK_WEBKIT
import WebKit
private typealias OAuthWebPage = WebKit.WebPage
private typealias OAuthWebView = WebKit.WebView
#endif

/// A browser tab showing an atproto account provider's authorization page.
@MainActor
struct OAuthAuthorizationView: View {
    @Environment(AppModel.self) private var app
    let id: UUID

    var body: some View {
        NavigationStack {
            Group {
                if let authorization = app.oauthAuthorizations[id], !authorization.isFinished {
                    authorizationPage(authorization)
                } else {
                    ContentUnavailableView(
                        "Sign-in ended", systemImage: "person.crop.circle.badge.checkmark",
                        description: Text("This sign-in is no longer in progress. You can close this tab.")
                    )
                }
            }
            .navigationTitle("Sign In")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    @ViewBuilder
    private func authorizationPage(_ authorization: OAuthTabAuthorization) -> some View {
        #if (canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))) || BACKEND_GTK_WEBKIT
        OAuthWebView(OAuthWebPageStore.shared.page(for: authorization))
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { authorization.cancel() }
                }
            }
        #else
        // OAuthTabPresenter.isSupported is false here, so the app signs in
        // with the system session and never opens this route.
        ContentUnavailableView("Sign-in unavailable", systemImage: "xmark.octagon",
                               description: Text("This build cannot show web pages in a tab."))
        #endif
    }
}

#if (canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))) || BACKEND_GTK_WEBKIT
/// Keeps each authorization's page until the authorization finishes, so
/// switching tabs or rebuilding the view does not reload a single-use
/// authorization request.
@MainActor
final class OAuthWebPageStore {
    static let shared = OAuthWebPageStore()
    private var pages: [OAuthTabAuthorization.ID: OAuthWebPage] = [:]

    fileprivate func page(for authorization: OAuthTabAuthorization) -> OAuthWebPage {
        if let page = pages[authorization.id] { return page }
        // The default, persistent data store keeps the provider's own login
        // between sign-ins, as the system authentication session would.
        let page = OAuthWebPage(
            configuration: OAuthWebPage.Configuration(),
            navigationDecider: OAuthNavigationDecider(authorization: authorization)
        )
        page.load(authorization.authorizationURL)
        pages[authorization.id] = page
        return page
    }

    /// Creates the page and starts loading it without showing it; for tests.
    func preparePage(for authorization: OAuthTabAuthorization) { _ = page(for: authorization) }

    /// The page's current URL, if it has one; for tests.
    func currentURL(for authorization: OAuthTabAuthorization) -> URL? { pages[authorization.id]?.url }

    func remove(_ authorization: OAuthTabAuthorization) {
        pages.removeValue(forKey: authorization.id)?.stopLoading()
    }
}

/// Answers the page's navigation-policy questions, which every backend asks
/// on the main thread for the initial load, link clicks, script navigations
/// and server redirects. The redirect back to the app is cancelled, so
/// WebKit never tries to open the custom scheme, and completes the sign-in.
@MainActor
private final class OAuthNavigationDecider: OAuthWebPage.NavigationDeciding {
    /// Weak: the page retains its decider, so a strong reference here would
    /// keep the authorization alive through its own page.
    private weak var authorization: OAuthTabAuthorization?

    init(authorization: OAuthTabAuthorization) { self.authorization = authorization }

    func decidePolicy(for action: OAuthWebPage.NavigationAction) -> OAuthWebPage.NavigationActionPolicy {
        guard let url = action.request.url, let authorization else { return .allow }
        return authorization.shouldLoad(url) ? .allow : .cancel
    }
}
#endif
