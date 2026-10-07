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

/// A JavaScript engine backed by a JavaScriptCore implementation provided by the platform.
public protocol JSEngine {
    /// Creates a context whose global scope has `__hostCall(name, a, b) -> string`, the only door from plugin
    /// code into the host. The prelude builds the plugin-facing API on top of it.
    func makeContext(hostCall: @escaping (_ name: String, _ a: String, _ b: String) -> String) throws -> JSContextHost
}

public enum JSEngines {
    #if canImport(CJavaScriptCoreGTK)
    private nonisolated(unsafe) static var bootstrapContext: JSContextHost?
    private static let bootstrapLock = NSLock()
    #endif
    /// The engine used by new plugin runtimes. Tests and embedders may replace it.
    nonisolated(unsafe) public static var `default`: JSEngine = {
        #if canImport(JavaScriptCore)
        return JavaScriptCoreEngine()
        #elseif canImport(CJavaScriptCoreGTK)
        return JavaScriptCoreGTKEngine()
        #else
        return UnavailableJavaScriptCoreEngine()
        #endif
    }()

    /// Initializes process-global engine state on the caller's thread.
    /// WebKitGTK and its standalone JavaScriptCore API share WTF's one-time
    /// main-thread registration, so GTK entry points call this before starting
    /// plugin work on background queues.
    public static func initializeDefaultRuntimeOnCurrentThread() throws {
        #if canImport(CJavaScriptCoreGTK)
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard bootstrapContext == nil else { return }
        // Keep the first context alive. JavaScriptCoreGTK tears down shared WTF
        // state when its last context disappears; recreating it later on a
        // plugin worker leaves WebKitGTK's web process unable to navigate.
        bootstrapContext = try self.default.makeContext { _, _, _ in "" }
        #else
        let context = try self.default.makeContext { _, _, _ in "" }
        context.close()
        #endif
    }
}

private struct UnavailableJavaScriptCoreEngine: JSEngine {
    func makeContext(hostCall: @escaping (_ name: String, _ a: String, _ b: String) -> String) throws -> JSContextHost {
        throw JSEngineError(message: "JavaScriptCore is not available on this platform")
    }
}
