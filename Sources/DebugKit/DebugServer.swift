import Foundation

#if DEBUG && canImport(Network)
import Network

/// A tiny, debug-build-only HTTP control plane for simulator automation.
///
/// The server is opt-in through `HUMMINGBIRD_DEBUG_SERVER_PORT`; release builds
/// compile a no-op implementation and never open a listener.
@MainActor
public final class DebugServer {
    public static let shared = DebugServer()

    private var probes: [String: @MainActor () -> String] = [:]
    private var actions: [String: @MainActor () -> Void] = [:]
    private var listener: NWListener?

    private init() {}

    public func registerProbe(_ name: String, _ probe: @escaping @MainActor () -> String) {
        probes[name] = probe
    }

    public func registerAction(_ name: String, _ action: @escaping @MainActor () -> Void) {
        actions[name] = action
    }

    public func startFromEnvironment() {
        guard listener == nil,
              let value = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_SERVER_PORT"],
              let rawPort = UInt16(value),
              let port = NWEndpoint.Port(rawValue: rawPort) else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: DispatchQueue(label: "Hummingbird.DebugServer"))
            self.listener = listener
        } catch {
            print("DebugServer failed to listen on port \(rawPort): \(error)")
        }
    }

    nonisolated private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "Hummingbird.DebugConnection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = self.response(to: request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func response(to request: String) -> Data {
        let firstLine = request.split(separator: "\n", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fields = firstLine.split(separator: " ")
        let method = fields.first.map(String.init) ?? ""
        let path = fields.count > 1 ? String(fields[1]) : "/"

        if method == "GET", path == "/state" {
            let values = probes.mapValues { $0() }
            return http(status: "200 OK", json: values)
        }
        if method == "GET", path == "/" {
            return http(status: "200 OK", json: [
                "probes": probes.keys.sorted().joined(separator: ","),
                "actions": actions.keys.sorted().joined(separator: ","),
            ])
        }
        if method == "POST", path.hasPrefix("/actions/") {
            let name = String(path.dropFirst("/actions/".count))
            guard let action = actions[name] else {
                return http(status: "404 Not Found", json: ["error": "unknown action"])
            }
            action()
            return http(status: "200 OK", json: ["action": name, "status": "ok"])
        }
        return http(status: "404 Not Found", json: ["error": "not found"])
    }

    private func http(status: String, json: [String: String]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }
}

#else

@MainActor
public final class DebugServer {
    public static let shared = DebugServer()
    private init() {}
    public func registerProbe(_ name: String, _ probe: @escaping @MainActor () -> String) {}
    public func registerAction(_ name: String, _ action: @escaping @MainActor () -> Void) {}
    public func startFromEnvironment() {}
}

#endif
