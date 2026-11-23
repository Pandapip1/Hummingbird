#if os(macOS)
import Foundation
import Synchronization
import XPC

/// Starts a plugin host as the app's XPC service (one instance per connection, see the service's
/// Info.plist) and hands it one end of a socket pair. Killing it ends that process only.
public struct XPCPluginHostLauncher: PluginHostLauncher {
    public let serviceName: String

    public init(serviceName: String) { self.serviceName = serviceName }

    public func launch() throws -> PluginHostProcess {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw PluginHostError.unavailable("socketpair failed (\(errno))")
        }
        let connection = xpc_connection_create(serviceName, nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_fd(message, "channel", fds[1])
        xpc_connection_send_message(connection, message)
        close(fds[1])
        let held = Mutex<xpc_connection_t?>(connection)
        return PluginHostProcess(channel: PluginHostChannel(readFD: fds[0], writeFD: fds[0])) {
            guard let connection = held.withLock({ value -> xpc_connection_t? in
                defer { value = nil }
                return value
            }) else { return }
            let pid = xpc_connection_get_pid(connection)
            if pid > 0 { _ = kill(pid, SIGKILL) }
            xpc_connection_cancel(connection)
        }
    }

    /// Whether the app bundle carries the service (Xcode builds do; xtool and SwiftPM builds don't).
    public static func isEmbedded(named name: String, in bundle: Bundle = .main) -> Bool {
        FileManager.default.fileExists(atPath: bundle.bundleURL
            .appendingPathComponent("Contents/XPCServices/\(name).xpc").path)
    }
}
#endif
