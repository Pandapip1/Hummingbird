import Foundation
import CQuickJS

/// QuickJS-NG backed engine. Portable: used on Linux and Android, and available on Apple platforms for comparison.
public struct QuickJSEngine: JSEngine {
    public init() {}
    public func makeContext(hostCall: @escaping (String, String, String) -> String) throws -> JSContextHost {
        try QuickJSContextHost(hostCall: hostCall)
    }
}

private func hostCallTrampoline(_ ctx: OpaquePointer?, _ this: JSValue, _ argc: Int32, _ argv: UnsafeMutablePointer<JSValue>?) -> JSValue {
    guard let ctx, let opaque = JS_GetContextOpaque(ctx) else { return cq_undefined() }
    let host = Unmanaged<QuickJSContextHost>.fromOpaque(opaque).takeUnretainedValue()
    func arg(_ i: Int) -> String {
        guard let argv, Int32(i) < argc else { return "" }
        var len = 0
        guard let p = JS_ToCStringLen(ctx, &len, argv[i]) else { return "" }
        defer { JS_FreeCString(ctx, p) }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    let result = host.hostCall(arg(0), arg(1), arg(2))
    return result.withCString { JS_NewStringLen(ctx, $0, strlen($0)) }
}

final class QuickJSContextHost: JSContextHost {
    let hostCall: (String, String, String) -> String
    private var runtime: OpaquePointer?
    private var context: OpaquePointer?

    init(hostCall: @escaping (String, String, String) -> String) throws {
        self.hostCall = hostCall
        guard let rt = JS_NewRuntime(), let ctx = JS_NewContext(rt) else { throw JSEngineError(message: "Could not create a JavaScript context") }
        runtime = rt
        context = ctx
        JS_SetMemoryLimit(rt, 512 * 1024 * 1024)
        // Plugin bundles routinely add several wrapper layers around host calls. Dispatch
        // workers have an 8 MiB stack on supported Linux builds, so leave 2 MiB for Swift
        // and native frames while allowing deeper real-world plugin call graphs.
        JS_SetMaxStackSize(rt, 6 * 1024 * 1024)
        JS_SetContextOpaque(ctx, Unmanaged.passUnretained(self).toOpaque())
        let global = JS_GetGlobalObject(ctx)
        let fn = JS_NewCFunction(ctx, hostCallTrampoline, "__hostCall", 3)
        JS_SetPropertyStr(ctx, global, "__hostCall", fn)   // takes ownership of fn
        JS_FreeValue(ctx, global)
    }

    deinit { close() }

    func close() {
        if let context { JS_FreeContext(context) }
        if let runtime { JS_FreeRuntime(runtime) }
        context = nil
        runtime = nil
    }

    func evaluate(_ code: String, name: String) throws -> String? {
        guard let ctx = context else { throw JSEngineError(message: "The JavaScript context is closed") }
        let value = code.withCString { src in
            name.withCString { file in
                JS_Eval(ctx, src, strlen(src), file, cq_eval_global())
            }
        }
        defer { JS_FreeValue(ctx, value) }
        if JS_IsException(value) { throw takeException(ctx) }
        drainJobs()
        if JS_IsUndefined(value) || JS_IsNull(value) { return nil }
        return string(of: value, ctx)
    }

    /// Plugins are synchronous, but runs any promise jobs a script queued so none are left pending.
    private func drainJobs() {
        guard let rt = runtime else { return }
        var jobCtx: OpaquePointer?
        while JS_IsJobPending(rt) { if JS_ExecutePendingJob(rt, &jobCtx) < 0 { break } }
    }

    private func string(of value: JSValue, _ ctx: OpaquePointer) -> String? {
        var len = 0
        guard let p = JS_ToCStringLen(ctx, &len, value) else { return nil }
        defer { JS_FreeCString(ctx, p) }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    private func takeException(_ ctx: OpaquePointer) -> JSEngineError {
        let ex = JS_GetException(ctx)
        defer { JS_FreeValue(ctx, ex) }
        var message = string(of: ex, ctx) ?? "Script error"
        var line: String?
        let lineValue = JS_GetPropertyStr(ctx, ex, "lineNumber")
        if !JS_IsUndefined(lineValue) { line = string(of: lineValue, ctx) }
        JS_FreeValue(ctx, lineValue)
        let stackValue = JS_GetPropertyStr(ctx, ex, "stack")
        if !JS_IsUndefined(stackValue), let stack = string(of: stackValue, ctx), !stack.isEmpty, line == nil { message += "\n" + stack }
        JS_FreeValue(ctx, stackValue)
        return JSEngineError(message: message, line: line)
    }
}
