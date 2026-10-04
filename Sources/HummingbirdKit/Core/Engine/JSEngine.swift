import Foundation

/// A script failed to compile or threw.
public struct JSEngineError: Error, CustomStringConvertible {
    public var message: String
    public var line: String?
    public init(message: String, line: String? = nil) { self.message = message; self.line = line }
    public var description: String { line.map { "\(message) (line \($0))" } ?? message }
}

/// One isolated JavaScript global environment. Not thread-safe: callers serialise access (PluginRuntime uses a queue).
public protocol JSContextHost: AnyObject {
    /// Runs `code` as a global script. Returns the JS string conversion of the result, or nil for undefined/null.
    func evaluate(_ code: String, name: String) throws -> String?
    /// Releases the engine resources. The context must not be used afterwards.
    func close()
}

/// A JavaScript engine. JavaScriptCore is preferred where the platform packages it; QuickJS is the portable fallback.
public protocol JSEngine {
    /// Creates a context whose global scope has `__hostCall(name, a, b) -> string`, the only door from plugin
    /// code into the host. The prelude builds the plugin-facing API on top of it.
    func makeContext(hostCall: @escaping (_ name: String, _ a: String, _ b: String) -> String) throws -> JSContextHost
}

public enum JSEngines {
    /// The engine used by new plugin runtimes. Tests and embedders may replace it.
    nonisolated(unsafe) public static var `default`: JSEngine = {
        #if canImport(JavaScriptCore)
        return JavaScriptCoreEngine()
        #elseif canImport(CJavaScriptCoreGTK)
        return JavaScriptCoreGTKEngine()
        #else
        return QuickJSEngine()
        #endif
    }()
}
