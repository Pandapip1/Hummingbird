import Foundation

/// Whether an authorization server can grant a scope, judged from its
/// `scopes_supported` metadata before anything is shown to the user.
///
/// `scopes_supported` is only a hint. RFC 8414 section 2 lets a server
/// leave supported scopes out of it, and the atproto permission spec
/// (atproto.com/specs/permission) does not say what servers advertise. The
/// reference implementation, @atproto/oauth-provider, lists only its static
/// scopes (`atproto` and the `transition:` scopes) and notes that "other
/// atproto scopes can't be enumerated as they are dynamic"
/// (src/metadata/build-metadata.ts). When a request reaches it, it keeps
/// only scopes that `isAtprotoOauthScope` recognizes (the static values and
/// the account, blob, identity, include, repo and rpc resources of the
/// permission spec; @atproto/oauth-scopes) and silently drops the rest
/// (src/request/request-manager.ts). So:
///
/// - A scope is `.advertised` when the list has it exactly, or, for a
///   parameterized scope (`resource:positional?key=value`), when the list
///   names its resource bare (`space`) or has any scope of that resource
///   (`space:…`, `space?…`). The `transition:` scopes are fixed values, so
///   they only ever match exactly.
/// - A scope of one of the permission spec's own resources that is not
///   listed is `.unknown`: servers implementing the spec support those
///   without enumerating them, so it is requested and the grant decides.
/// - Anything else that is not listed is `.notAdvertised`. A server that
///   does not know the resource would drop it without telling the user.
/// - Without `scopes_supported` every scope is `.unknown`.
public enum OAuthScopeAvailability: Sendable, Hashable {
    case advertised
    case unknown
    case notAdvertised

    /// The resources defined by the atproto permission spec.
    static let permissionSpecResources: Set<String> = ["account", "blob", "identity", "include", "repo", "rpc"]

    public static func of(_ scope: String, scopesSupported: [String]?) -> OAuthScopeAvailability {
        guard let scopesSupported else { return .unknown }
        if scopesSupported.contains(scope) { return .advertised }
        guard let resource = resource(of: scope) else { return .notAdvertised }
        let covered = scopesSupported.contains { entry in
            entry == resource || entry.hasPrefix(resource + ":") || entry.hasPrefix(resource + "?")
        }
        if covered { return .advertised }
        return permissionSpecResources.contains(resource) ? .unknown : .notAdvertised
    }

    /// The resource name of a parameterized scope, or nil for a static
    /// scope value such as `atproto` or `transition:generic`.
    static func resource(of scope: String) -> String? {
        guard let end = scope.firstIndex(where: { $0 == ":" || $0 == "?" }) else { return nil }
        let resource = String(scope[..<end])
        return resource == "transition" || resource.isEmpty ? nil : resource
    }
}

/// An account and its authorization server, examined before anything is
/// shown to the user: which of the client's scopes will be requested, and
/// which optional ones the server does not support and are left out.
public struct ATProtoPreparedAuthorization: Sendable {
    public let identity: ResolvedIdentity
    /// The scopes the authorization request will ask for, in the client's
    /// order.
    public let requestedScopes: [String]
    /// Optional scopes the server does not advertise. They are not
    /// requested, so the consent screen shows only what can be granted.
    public let unsupportedScopes: [String]
    let metadata: OAuthAuthorizationServerMetadata

    /// Splits the client's scopes by what the server advertises. Throws
    /// when a required scope is not advertised, before anything opens.
    init(identity: ResolvedIdentity, metadata: OAuthAuthorizationServerMetadata,
         scopes: [String], requiredScopes: Set<String>) throws {
        var requested: [String] = []
        var unsupported: [String] = []
        var missingRequired: [String] = []
        for scope in scopes {
            let available = OAuthScopeAvailability.of(scope, scopesSupported: metadata.scopesSupported) != .notAdvertised
            if available { requested.append(scope) }
            else if requiredScopes.contains(scope) { missingRequired.append(scope) }
            else { unsupported.append(scope) }
        }
        guard missingRequired.isEmpty else {
            throw OAuthError.requiredScopesUnsupported(server: metadata.issuer, scopes: missingRequired)
        }
        self.identity = identity
        self.metadata = metadata
        requestedScopes = requested
        unsupportedScopes = unsupported
    }
}
