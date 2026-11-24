import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

/// The messages between the app and a plugin host process: length-prefixed JSON frames on a byte
/// stream (a pipe pair or a socket). The host process holds nothing but JavaScript contexts; every
/// capability (network, storage, logging, the DOM) stays in the app and is reached only through
/// `hostCall` messages that the app answers.
public enum PluginHostMessage: Codable, Sendable, Equatable {
    // app → host
    case create(context: Int)
    case evaluate(context: Int, id: Int, code: String, name: String)
    case hostReply(context: Int, id: Int, value: String)
    case close(context: Int)
    // host → app
    case created(context: Int, error: String?)
    case result(context: Int, id: Int, value: String?, error: String?, line: String?)
    case hostCall(context: Int, id: Int, name: String, a: String, b: String)

    public var context: Int {
        switch self {
        case .create(let c), .close(let c): c
        case .evaluate(let c, _, _, _), .hostReply(let c, _, _), .created(let c, _),
             .result(let c, _, _, _, _), .hostCall(let c, _, _, _, _): c
        }
    }
}

/// Reads and writes frames on file descriptors. Writes are serialised; one reader at a time.
public final class PluginHostChannel: Sendable {
    /// A frame larger than this ends the connection (a script or result over it is refused).
    public static let maximumFrameBytes = 96 * 1024 * 1024

    private let readFD: Int32
    private let writeFD: Int32
    private let writeLock = Mutex(())
    private let closed = Mutex(false)

    public init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
    }

    public func send(_ message: PluginHostMessage) throws {
        let body = try JSONEncoder().encode(message)
        guard body.count <= Self.maximumFrameBytes else { throw PluginHostError.frameTooLarge }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try writeLock.withLock { _ in try Self.writeAll(writeFD, frame) }
    }

    /// The next message, or nil at end of stream.
    public func receive() throws -> PluginHostMessage? {
        guard let header = try Self.read(readFD, count: 4) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= Self.maximumFrameBytes else { throw PluginHostError.frameTooLarge }
        guard let body = try Self.read(readFD, count: length) else { return nil }
        return try JSONDecoder().decode(PluginHostMessage.self, from: body)
    }

    public func close() {
        let first: Bool = closed.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        _ = shutdown(readFD, Int32(SHUT_RDWR))
        _ = closeDescriptor(readFD)
        if writeFD != readFD { _ = closeDescriptor(writeFD) }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PluginHostError.connectionLost
                }
                offset += n
            }
        }
    }

    private static func read(_ fd: Int32, count: Int) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { raw in
                Foundation.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            offset += n
        }
        return data
    }
}

/// `close(2)`, named apart from `PluginHostChannel.close()`.
@inline(__always) func closeDescriptor(_ fd: Int32) -> Int32 { close(fd) }

public enum PluginHostError: Error, CustomStringConvertible {
    case frameTooLarge, connectionLost, unavailable(String)
    public var description: String {
        switch self {
        case .frameTooLarge: "The plugin host message is too large"
        case .connectionLost: "The plugin host process ended"
        case .unavailable(let why): "The plugin host could not start: \(why)"
        }
    }
}
