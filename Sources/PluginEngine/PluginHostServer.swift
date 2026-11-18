import Foundation
import Synchronization
import CPluginHostSandbox

/// The plugin host process's side: holds JavaScript contexts and nothing else. Each context lives on
/// a thread of its own, which owns the context outright; messages reach it through its inbox. A host
/// call is sent to the app and the script waits for the reply, exactly as an in-process context waits
/// for a native call.
public final class PluginHostServer: Sendable {
    private let channel: PluginHostChannel
    private let engine: any JSEngine & Sendable
    private let inboxes = Mutex<[Int: Inbox]>([:])

    public init(channel: PluginHostChannel, engine: any JSEngine & Sendable) {
        self.channel = channel
        self.engine = engine
    }

    /// Serves until the app closes the connection (or the process is killed).
    public func run() {
        while let message = try? channel.receive() {
            switch message {
            case .create(let id):
                let inbox = Inbox()
                inboxes.withLock { $0[id] = inbox }
                Self.startContext(id: id, inbox: inbox, channel: channel, engine: engine)
            case .evaluate, .hostReply:
                if let inbox = inboxes.withLock({ $0[message.context] }) {
                    inbox.deliver(message)
                } else if case .evaluate(let id, let evaluation, _, _) = message {
                    try? channel.send(.result(context: id, id: evaluation, value: nil, error: "No such context", line: nil))
                }
            case .close(let id):
                inboxes.withLock { $0.removeValue(forKey: id) }?.deliver(message)
            case .created, .result, .hostCall:
                break
            }
        }
        for inbox in inboxes.withLock({ Array($0.values) }) { inbox.end() }
        channel.close()
    }

    /// Messages for one context, in order.
    final class Inbox: Sendable {
        private let messages = Mutex<[PluginHostMessage]>([])
        private let ended = Mutex(false)
        private let signal = DispatchSemaphore(value: 0)

        func deliver(_ message: PluginHostMessage) {
            messages.withLock { $0.append(message) }
            signal.signal()
        }

        func end() {
            ended.withLock { $0 = true }
            signal.signal()
        }

        func next() -> PluginHostMessage? {
            while true {
                if let message: PluginHostMessage = messages.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return message }
                if ended.withLock({ $0 }) { return nil }
                signal.wait()
            }
        }
    }

    /// What a context's thread keeps between messages: replies it has not consumed yet and
    /// messages that arrived while it waited for one.
    private final class ThreadState {
        var nextCall = 1
        var deferred: [PluginHostMessage] = []
    }

    private static func startContext(id: Int, inbox: Inbox, channel: PluginHostChannel, engine: any JSEngine & Sendable) {
        let thread = Thread {
            let state = ThreadState()
            func next() -> PluginHostMessage? {
                state.deferred.isEmpty ? inbox.next() : state.deferred.removeFirst()
            }
            // Runs on this thread, inside an evaluation: asks the app and waits for its answer.
            let hostCall: (String, String, String) -> String = { name, a, b in
                let call = state.nextCall
                state.nextCall += 1
                guard (try? channel.send(.hostCall(context: id, id: call, name: name, a: a, b: b))) != nil else { return "" }
                while let message = inbox.next() {
                    if case .hostReply(_, let replyTo, let value) = message, replyTo == call { return value }
                    state.deferred.append(message)
                }
                return ""
            }
            let context: JSContextHost
            do {
                context = try engine.makeContext(hostCall: hostCall)
                try? channel.send(.created(context: id, error: nil))
            } catch {
                try? channel.send(.created(context: id, error: "\(error)"))
                return
            }
            defer { context.close() }
            while let message = next() {
                switch message {
                case .evaluate(_, let evaluation, let code, let name):
                    let reply: PluginHostMessage
                    do {
                        reply = .result(context: id, id: evaluation, value: try context.evaluate(code, name: name), error: nil, line: nil)
                    } catch let error as JSEngineError {
                        reply = .result(context: id, id: evaluation, value: nil, error: error.message, line: error.line)
                    } catch {
                        reply = .result(context: id, id: evaluation, value: nil, error: "\(error)", line: nil)
                    }
                    try? channel.send(reply)
                case .close:
                    return
                default:
                    continue
                }
            }
        }
        thread.name = "app.hummingbird.plugin-host.context.\(id)"
        thread.stackSize = 8 << 20
        thread.start()
    }
}

public extension PluginHostServer {
    /// Runs this process as a plugin host on stdin/stdout, then exits. Called first thing by the
    /// host executable (and by the Linux app binary started with `--plugin-host`).
    static func runAsProcess() -> Never {
        // Nothing the parent had open reaches plugin code, only the two frame streams.
        for fd in Int32(3)..<Int32(1024) { _ = closeDescriptor(fd) }
        _ = hb_plugin_host_sandbox()
        PluginHostServer(channel: PluginHostChannel(readFD: 0, writeFD: 1), engine: JSEngines.makeInProcess()).run()
        exit(0)
    }
}
