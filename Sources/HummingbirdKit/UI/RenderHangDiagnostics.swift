#if DEBUG && os(iOS)
import Foundation
import MetricKit

/// Persists Apple's symbolication-ready hang diagnostics for later retrieval
/// from the app container. MetricKit delivers them asynchronously, often on a
/// subsequent launch rather than at the instant a hang occurs.
@MainActor
public enum RenderHangDiagnostics {
    public static func start() {
        MetricHangRecorder.shared.start()
    }
}

private final class MetricHangRecorder: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    @MainActor static let shared = MetricHangRecorder()
    private let writer = DispatchQueue(label: "app.hummingbird.metric-hangs", qos: .utility)
    private var started = false

    @MainActor
    func start() {
        guard !started else { return }
        started = true
        let manager = MXMetricManager.shared
        manager.add(self)
        persist(manager.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        persist(payloads)
    }

    private func persist(_ payloads: [MXDiagnosticPayload]) {
        let hangs = payloads.filter { !($0.hangDiagnostics?.isEmpty ?? true) }
        guard !hangs.isEmpty else { return }
        writer.async {
            do {
                let directory = try Self.directory()
                for payload in hangs {
                    let begin = Int(payload.timeStampBegin.timeIntervalSince1970)
                    let end = Int(payload.timeStampEnd.timeIntervalSince1970)
                    let url = directory.appendingPathComponent("hang-\(begin)-\(end).json")
                    try payload.jsonRepresentation().write(to: url, options: .atomic)
                }
            } catch {
                // Diagnostics must never affect the application being measured.
            }
        }
    }

    private static func directory() throws -> URL {
        let directory = try RenderDiagnosticsStorage.root()
            .appendingPathComponent("metric-hangs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
