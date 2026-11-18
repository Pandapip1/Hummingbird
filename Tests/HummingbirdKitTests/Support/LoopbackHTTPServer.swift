import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A minimal HTTP/1.1 server on 127.0.0.1 for tests that need a real socket
/// (the egress proxy connects to it). Answers every request with `body` and
/// records request heads. Never leaves loopback.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: Int
    private let socketFD: Int32
    private let lock = NSLock()
    private var heads: [String] = []
    private let body: String
    private var closed = false

    var requests: [String] { lock.withLock { heads } }

    init(body: String = "ok") throws {
        self.body = body
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw URLError(.cannotConnectToHost) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socketFD = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    func stop() {
        lock.withLock { closed = true }
        shutdown(socketFD, Int32(SHUT_RDWR))
        close(socketFD)
    }

    private func acceptLoop() {
        while !lock.withLock({ closed }) {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < 65_536 {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return }
            received.append(buffer, count: n)
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        lock.withLock { heads.append(String(decoding: received, as: UTF8.self)) }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { write(client, $0, strlen($0)) }
    }
}
