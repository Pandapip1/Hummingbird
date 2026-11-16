import Foundation

// Token responses hold bearer tokens as plain strings until they are moved
// into SecureBytes. Keep them out of `po`, `print` and `dump`; the lldb
// formatters in Hummingbird's Tools/lldb hide them from `frame variable` too.
extension OAuthTokenResponse: CustomDebugStringConvertible, CustomReflectable {
    var debugDescription: String {
        "OAuthTokenResponse(\(tokenType), scope: \(scope), sub: \(sub), expiresIn: \(expiresIn.map(String.init) ?? "nil"), tokens redacted)"
    }

    var customMirror: Mirror {
        Mirror(self, children: [
            "tokenType": tokenType,
            "scope": scope,
            "sub": sub,
            "expiresIn": expiresIn as Any,
            "accessToken": "\(accessToken.utf8.count) bytes, redacted",
            "refreshToken": refreshToken.map { "\($0.utf8.count) bytes, redacted" } as Any,
        ], displayStyle: .struct)
    }
}
