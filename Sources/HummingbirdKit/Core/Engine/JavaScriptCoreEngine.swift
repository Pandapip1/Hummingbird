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
        let value = ctx.evaluateScript(code, withSourceURL: URL(string: "hummingbird://plugin/\(name.replacingOccurrences(of: " ", with: "_"))"))
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

#if canImport(CJavaScriptCoreGTK)
import CJavaScriptCoreGTK

/// JavaScriptCore's GLib API, supplied by WebKitGTK on Linux.
public struct JavaScriptCoreGTKEngine: JSEngine {
    public init() {}

    public func makeContext(hostCall: @escaping (String, String, String) -> String) throws -> JSContextHost {
        guard let context = jsc_context_new() else {
            throw JSEngineError(message: "Could not create a JavaScript context")
        }
        let box = Unmanaged.passRetained(JavaScriptCoreGTKHostCall(hostCall))
        hummingbird_jsc_install_host_call(context, { name, first, second, opaque in
            guard let opaque else { return strdup("") }
            let host = Unmanaged<JavaScriptCoreGTKHostCall>.fromOpaque(opaque).takeUnretainedValue()
            let result = host.call(
                name.map(String.init(cString:)) ?? "",
                first.map(String.init(cString:)) ?? "",
                second.map(String.init(cString:)) ?? ""
            )
            return strdup(result)
        }, box.toOpaque(), { opaque in
            guard let opaque else { return }
            Unmanaged<JavaScriptCoreGTKHostCall>.fromOpaque(opaque).release()
        })
        return JavaScriptCoreGTKContextHost(context)
    }
}

private final class JavaScriptCoreGTKHostCall {
    let call: (String, String, String) -> String
    init(_ call: @escaping (String, String, String) -> String) { self.call = call }
}

final class JavaScriptCoreGTKContextHost: JSContextHost {
    private var context: OpaquePointer?

    init(_ context: OpaquePointer) { self.context = context }
    deinit { close() }

    func evaluate(_ code: String, name: String) throws -> String? {
        guard let context else { throw JSEngineError(message: "The JavaScript context is closed") }
        let sourceURI = "hummingbird://plugin/\(name.replacingOccurrences(of: " ", with: "_"))"
        let value = code.withCString { source in
            sourceURI.withCString { uri in
                jsc_context_evaluate_with_source_uri(context, source, -1, uri, 1)
            }
        }
        guard let value else { throw JSEngineError(message: "JavaScriptCore returned no value") }
        defer { hummingbird_jsc_unref(UnsafeMutableRawPointer(value)) }

        if let exception = jsc_context_get_exception(context) {
            let message = jsc_exception_get_message(exception).map(String.init(cString:)) ?? "Script error"
            let lineNumber = jsc_exception_get_line_number(exception)
            jsc_context_clear_exception(context)
            throw JSEngineError(message: message, line: lineNumber == 0 ? nil : String(lineNumber))
        }
        if jsc_value_is_undefined(value) != 0 || jsc_value_is_null(value) != 0 { return nil }
        guard let string = jsc_value_to_string(value) else { return nil }
        defer { hummingbird_jsc_free(string) }
        return String(cString: string)
    }

    func close() {
        guard let context else { return }
        hummingbird_jsc_unref(UnsafeMutableRawPointer(context))
        self.context = nil
    }
}
#endif
