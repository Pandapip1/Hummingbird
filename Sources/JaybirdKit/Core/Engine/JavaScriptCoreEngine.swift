#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Apple's JavaScriptCore, via the Objective-C API.
public struct JavaScriptCoreEngine: JSEngine {
    public init() {}
    public func makeContext(hostCall: @escaping (String, String, String) -> String) throws -> JSContextHost {
        guard let ctx = JSContext() else { throw JSEngineError(message: "Could not create a JavaScript context") }
        let block: @convention(block) (String, String, String) -> String = { n, a, b in hostCall(n, a, b) }
        ctx.setObject(block, forKeyedSubscript: "__hostCall" as NSString)
        return JavaScriptCoreContextHost(ctx)
    }
}

final class JavaScriptCoreContextHost: JSContextHost {
    private var context: JSContext?
    init(_ context: JSContext) { self.context = context }

    func evaluate(_ code: String, name: String) throws -> String? {
        guard let ctx = context else { throw JSEngineError(message: "The JavaScript context is closed") }
        let value = ctx.evaluateScript(code, withSourceURL: URL(string: "jaybird://plugin/\(name.replacingOccurrences(of: " ", with: "_"))"))
        if let ex = ctx.exception {
            ctx.exception = nil
            throw JSEngineError(message: ex.toString() ?? "Script error", line: ex.objectForKeyedSubscript("line")?.toString())
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }

    func close() { context = nil }
}
#endif
