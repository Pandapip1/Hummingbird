import Foundation

// What `po` (and `print`, `dump`, Xcode's variables view) shows for types
// whose default output is unhelpful or would reveal secrets. Values that are
// secrets (cookies, header values, pairing secrets) are never printed, only
// counted or named. Tools/lldb/hummingbird.lldb adds matching summaries and
// child filters for `p` and `frame variable`, which read memory directly and
// do not consult these conformances.

extension SourceAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let cookies = cookieMap.values.reduce(0) { $0 + $1.count }
        let headerCount = headers.values.reduce(0) { $0 + $1.count }
        return "SourceAuth(\(cookies) cookies, \(headerCount) headers across \(Set(cookieMap.keys).union(headers.keys).count) domains, values redacted)"
    }

    public var debugDescription: String { description }

    /// Domains and names, never values.
    public var customMirror: Mirror {
        Mirror(self, children: [
            "cookieNames": cookieMap.mapValues { $0.keys.sorted() },
            "headerNames": headers.mapValues { $0.keys.sorted() },
            "userAgent": userAgent as Any,
        ], displayStyle: .struct)
    }
}

extension CredentialPairingRequest: CustomDebugStringConvertible, CustomReflectable {
    var debugDescription: String {
        "CredentialPairingRequest(plugin: \(pluginID), endpoint: \(endpoint.host ?? "?"), secret: \(secret.count) bytes redacted)"
    }

    var customMirror: Mirror {
        Mirror(self, children: [
            "endpoint": endpoint,
            "pluginID": pluginID,
            "pluginSourceURL": pluginSourceURL,
            "receiver": receiver,
            "secret": "\(secret.count) bytes, redacted",
        ], displayStyle: .struct)
    }
}

extension InstalledPlugin: CustomDebugStringConvertible, CustomReflectable {
    var debugDescription: String {
        "InstalledPlugin(\(config.id) \"\(config.name)\" v\(config.version), \(enabled ? "enabled" : "disabled"), script \(script.utf8.count) bytes, settings: \(settings.keys.sorted()))"
    }

    /// Setting values can be tokens a plugin asks for, and the script is
    /// large: show names and sizes.
    var customMirror: Mirror {
        Mirror(self, children: [
            "config": config,
            "enabled": enabled,
            "scriptBytes": script.utf8.count,
            "settingKeys": settings.keys.sorted(),
        ], displayStyle: .struct)
    }
}

extension PluginRuntime: CustomDebugStringConvertible {
    /// Only immutable state: everything else belongs to the runtime's queue.
    var debugDescription: String {
        let patches = appliedCompatibilityPatches.isEmpty ? "" : ", patches: \(appliedCompatibilityPatches)"
        return "PluginRuntime(\(config.id) \"\(config.name)\" v\(config.version), signed in: \(isLoggedIn)\(patches))"
    }
}
