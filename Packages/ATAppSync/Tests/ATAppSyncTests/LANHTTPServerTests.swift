import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ATAppSync

/// The LAN server must deliver a whole reply before closing the connection,
/// even when the peer reads slowly and the reply is far larger than the
/// socket buffers (a phone on Wi-Fi pulling a journal snapshot).
final class LANHTTPServerTests: XCTestCase {
    func testLargeReplyArrivesWholeToSlowReader() async throws {
        let body = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.socketOption(.so_sndbuf), value: 16 * 1024)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(InboxAppendHTTPHandler { _, _ in
                        LANHTTPResponse(status: .ok, body: body, contentType: "application/octet-stream")
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)

        let received = try await Task.detached { try Self.slowlyRead(port: port) }.value
        let separator = Data("\r\n\r\n".utf8)
        let headerEnd = try XCTUnwrap(received.range(of: separator))
        XCTAssertEqual(received[headerEnd.upperBound...].count, body.count)
        XCTAssertEqual(Data(received[headerEnd.upperBound...]), body)

        try await server.close()
        try await group.shutdownGracefully()
    }

    /// Sends one request over a socket with a small receive buffer, waits
    /// so the server's writes back up, then reads until the server closes.
    private static func slowlyRead(port: Int) throws -> Data {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }
        var size: Int32 = 8 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        let request = "POST /appsync/v1/sync HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n{}"
        _ = request.utf8CString.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count - 1, 0) }
        usleep(500_000)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            // Read slowly, like a phone on Wi-Fi.
            if data.count % (256 * 1024) < 4096 { usleep(10_000) }
        }
        return data
    }
}
