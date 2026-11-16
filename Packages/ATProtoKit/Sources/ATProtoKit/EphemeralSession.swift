import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The HTTP session ATProtoKit uses unless one is injected: ephemeral, with
/// no cookie jar, no credential store and no cache. `URLSession.shared`
/// would share the process-wide cookie jar and cache (on Apple platforms
/// also seen by other parts of the app), so identity lookups, OAuth requests
/// and XRPC calls could carry or leave state they did not deliberately set.
/// Each client gets its own session.
public enum ATProtoHTTPSession {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public static func make() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }
}
