#if canImport(Network)
import Foundation
import Network
import Synchronization

/// A minimal stand-in for an atproto authorization server's browser side,
/// modelled on Bluesky's oauth-provider. The first GET of
/// /oauth/authorize binds the single-use request to the browser's device
/// cookie (setting one if the browser has none). Any later GET of the same
/// request, or a consent from a different device, is refused with a
/// redirect carrying `error=access_denied` and "This request was initiated
/// from another device". The page itself then consents through a script,
/// which only succeeds with the cookie from the first response.
final class FakeAuthorizationServer: Sendable {
    struct Options: Sendable {
        /// Bind the request on the first GET, then drop the connection
        /// without answering, as a lost response would.
        var dropFirstAuthorizeResponse = false
    }

    private struct State {
        var authorizeRequests = 0
        var boundDevice: String?
        var nextDevice = 0
        var log: [String] = []
    }

    static let requestURI = "urn:ietf:params:oauth:request_uri:req-test"
    let callback: String
    private let options: Options
    private let listener: NWListener
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "test.fake-authorization-server")

    init(callback: String, options: Options = Options()) throws {
        self.callback = callback
        self.options = options
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// How many times /oauth/authorize was requested.
    var authorizeRequests: Int { state.withLock { $0.authorizeRequests } }

    /// Every request's path, in order, and what it was answered with (failure diagnostics).
    var requestLog: [String] { state.withLock { $0.log } }

    struct StartFailure: Error, CustomStringConvertible { let description: String }

    /// Starts listening and returns the authorization URL to load. Throws if the listener fails,
    /// is cancelled, or is not ready within `timeout`, rather than waiting forever.
    func start(timeout: TimeInterval = 10) async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            let resume: @Sendable (Result<UInt16, any Error>) -> Void = { result in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { resume(.success(port)) }
                case .failed(let error):
                    resume(.failure(StartFailure(description: "the listener failed: \(error)")))
                case .cancelled:
                    resume(.failure(StartFailure(description: "the listener was cancelled")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(StartFailure(description: "the listener was not ready within \(timeout) s")))
            }
        }
        let query = "client_id=https%3A%2F%2Fapp.example%2Fclient.json&request_uri="
            + (Self.requestURI.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return URL(string: "http://127.0.0.1:\(port)/oauth/authorize?\(query)")!
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if error == nil, !complete {
                self.receiveRequest(on: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let cookie = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("cookie:") }
            .flatMap { line in
                line.dropFirst("cookie:".count).split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix("dev-id=") }
                    .map { String($0.dropFirst("dev-id=".count)) }
            }
        let path = String(target.split(separator: "?").first ?? "")
        state.withLock { $0.log.append(path + (cookie == nil ? "" : " (cookie)")) }
        let refusal = callback + "?error=access_denied&error_description=This+request+was+initiated+from+another+device"
            + "&state=test-state"

        switch path {
        case "/oauth/authorize":
            enum Outcome { case page(device: String, isNew: Bool), drop, refuse }
            let outcome: Outcome = state.withLock { state in
                state.authorizeRequests += 1
                let device: String
                let isNew: Bool
                if let cookie { device = cookie; isNew = false } else {
                    state.nextDevice += 1
                    device = "device-\(state.nextDevice)"
                    isNew = true
                }
                guard state.boundDevice == nil else { return .refuse }
                state.boundDevice = device
                if options.dropFirstAuthorizeResponse, state.authorizeRequests == 1 { return .drop }
                return .page(device: device, isNew: isNew)
            }
            switch outcome {
            case .drop:
                connection.cancel()
            case .refuse:
                send("HTTP/1.1 302 Found\r\nLocation: \(refusal)\r\n", body: "", on: connection)
            case .page(let device, let isNew):
                let setCookie = isNew ? "Set-Cookie: dev-id=\(device); Path=/; HttpOnly; SameSite=Lax\r\n" : ""
                let html = "<html><head><title>Sign in</title></head><body>Sign in"
                    + "<script>setTimeout(() => location.href = '/oauth/authorize/accept', 50)</script></body></html>"
                send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\(setCookie)", body: html, on: connection)
            }
        case "/oauth/authorize/accept":
            let accepted = state.withLock { $0.boundDevice != nil && $0.boundDevice == cookie }
            let location = accepted ? callback + "?code=granted&state=test-state" : refusal
            send("HTTP/1.1 302 Found\r\nLocation: \(location)\r\n", body: "", on: connection)
        default:
            send("HTTP/1.1 404 Not Found\r\n", body: "", on: connection)
        }
    }

    private func send(_ head: String, body: String, on connection: NWConnection) {
        let response = head + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
