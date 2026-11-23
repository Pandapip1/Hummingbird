import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

/// Starts a plugin host process and returns a channel to it and a way to kill it.
public protocol PluginHostLauncher: Sendable {
    func launch() throws -> PluginHostProcess
}

/// A running plugin host process.
public struct PluginHostProcess: Sendable {
    public let channel: PluginHostChannel
    /// Ends the process at once (SIGKILL); safe to call more than once.
    public let kill: @Sendable () -> Void
    /// The process's ID where known (diagnostics and measurements), else 0.
    public let pid: Int32

    public init(channel: PluginHostChannel, pid: Int32 = 0, kill: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.channel = channel
        self.kill = kill
    }
}

/// A JavaScript engine whose contexts live in a separate plugin host process, which the app can kill.
/// One process per engine (per plugin): killing it ends only that plugin's contexts. The next context
/// after a kill starts a new process.
public final class RemoteJSEngine: JSEngine, Sendable {
    private let launcher: any PluginHostLauncher
    private let current = Mutex<HostConnection?>(nil)
    private let nextContext = Mutex(1)

    public init(launcher: any PluginHostLauncher) {
        self.launcher = launcher
    }

    public func makeContext(hostCall: @escaping (String, String, String) -> String) throws -> JSContextHost {
        let connection = try connection()
        let id = nextContext.withLock { value in
            defer { value += 1 }
            return value
        }
        let context = RemoteJSContextHost(id: id, connection: connection, hostCall: hostCall)
        try context.create()
        return context
    }

    /// Kills the host process; every context in it fails at once.
    public func terminate() {
        let connection: HostConnection? = current.withLock { value in
            defer { value = nil }
            return value
        }
        connection?.terminate()
    }

    /// Whether a host process is running.
    public var isRunning: Bool { current.withLock { $0?.isAlive ?? false } }

    /// The running host process's ID, where known.
    public var processIdentifier: Int32? { current.withLock { $0.flatMap { $0.isAlive ? $0.pid : nil } } }

    private func connection() throws -> HostConnection {
        try current.withLock { value in
            if let value, value.isAlive { return value }
            let made = HostConnection(process: try launcher.launch())
            value = made
            return made
        }
    }
}

/// The app's end of one host process: routes incoming messages to the context they belong to.
final class HostConnection: Sendable {
    private let process: PluginHostProcess
    var pid: Int32 { process.pid }
    private let mailboxes = Mutex<[Int: Mailbox]>([:])
    private let alive = Mutex(true)

    final class Mailbox: Sendable {
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

        /// The next message for this context, or nil once the connection ended.
        func next() -> PluginHostMessage? {
            while true {
                if let message: PluginHostMessage = messages.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { return message }
                if ended.withLock({ $0 }) { return nil }
                signal.wait()
            }
        }
    }

    init(process: PluginHostProcess) {
        self.process = process
        let thread = Thread { [self] in readLoop() }
        thread.name = "app.hummingbird.plugin-host.reader"
        thread.start()
    }

    var isAlive: Bool { alive.withLock { $0 } }

    func mailbox(for context: Int) -> Mailbox {
        mailboxes.withLock { boxes in
            if let box = boxes[context] { return box }
            let box = Mailbox()
            boxes[context] = box
            if !isAlive { box.end() }
            return box
        }
    }

    func forget(_ context: Int) { _ = mailboxes.withLock { $0.removeValue(forKey: context) } }

    func send(_ message: PluginHostMessage) throws {
        guard isAlive else { throw PluginHostError.connectionLost }
        do { try process.channel.send(message) } catch {
            ended()
            throw error
        }
    }

    func terminate() {
        process.kill()
        ended()
    }

    private func readLoop() {
        while let message = try? process.channel.receive() {
            mailbox(for: message.context).deliver(message)
        }
        ended()
    }

    private func ended() {
        let first: Bool = alive.withLock { value in
            defer { value = false }
            return value
        }
        guard first else { return }
        process.channel.close()
        process.kill()
        for box in mailboxes.withLock({ Array($0.values) }) { box.end() }
    }
}

/// A context in the host process. Like every `JSContextHost`, used from one thread at a time: the
/// evaluating thread also answers the context's host calls, so they run where an in-process
/// context's would.
final class RemoteJSContextHost: JSContextHost {
    private let id: Int
    private let connection: HostConnection
    private let hostCall: (String, String, String) -> String
    private var nextEvaluation = 1
    private var closed = false

    init(id: Int, connection: HostConnection, hostCall: @escaping (String, String, String) -> String) {
        self.id = id
        self.connection = connection
        self.hostCall = hostCall
    }

    func create() throws {
        try connection.send(.create(context: id))
        let box = connection.mailbox(for: id)
        while let message = box.next() {
            if case .created(_, let error) = message {
                if let error { throw JSEngineError(message: error) }
                return
            }
        }
        throw JSEngineError(message: PluginHostError.connectionLost.description)
    }

    func evaluate(_ code: String, name: String) throws -> String? {
        guard !closed else { throw JSEngineError(message: "The JavaScript context is closed") }
        let evaluation = nextEvaluation
        nextEvaluation += 1
        do { try connection.send(.evaluate(context: id, id: evaluation, code: code, name: name)) } catch {
            throw JSEngineError(message: PluginHostError.connectionLost.description)
        }
        let box = connection.mailbox(for: id)
        while let message = box.next() {
            switch message {
            case .hostCall(_, let call, let name, let a, let b):
                let value = hostCall(name, a, b)
                try? connection.send(.hostReply(context: id, id: call, value: value))
            case .result(_, let resultID, let value, let error, let line) where resultID == evaluation:
                if let error { throw JSEngineError(message: error, line: line) }
                return value
            default:
                continue
            }
        }
        throw JSEngineError(message: PluginHostError.connectionLost.description)
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? connection.send(.close(context: id))
        connection.forget(id)
    }
}

#if os(macOS) || os(Linux) || os(Windows)
/// Launches the plugin host as a child process (Linux, and macOS outside the App Store sandbox, such
/// as tests): stdin/stdout carry the frames, and the process is killed with SIGKILL.
public struct SubprocessPluginHostLauncher: PluginHostLauncher {
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func launch() throws -> PluginHostProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--plugin-host"]
        // Nothing of the app's environment: the host needs none, and secrets must not leak into it.
        process.environment = [:]
        let toHost = Pipe(), fromHost = Pipe()
        process.standardInput = toHost
        process.standardOutput = fromHost
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw PluginHostError.unavailable("\(error)") }
        // The channel owns duplicates of the app's two pipe ends; the Pipe and Process objects
        // (and the child's ends, which only the child needs) go away with this scope.
        let readFD = dup(fromHost.fileHandleForReading.fileDescriptor)
        let writeFD = dup(toHost.fileHandleForWriting.fileDescriptor)
        guard readFD >= 0, writeFD >= 0 else { throw PluginHostError.unavailable("dup failed (\(errno))") }
        let pid = process.processIdentifier
        let once = Mutex(false)
        return PluginHostProcess(channel: PluginHostChannel(readFD: readFD, writeFD: writeFD), pid: pid) {
            guard once.withLock({ done in defer { done = true }; return !done }) else { return }
            _ = Foundation.kill(pid, SIGKILL)
            // Reap it, so a killed host never lingers as a zombie.
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
    }
}
#endif
