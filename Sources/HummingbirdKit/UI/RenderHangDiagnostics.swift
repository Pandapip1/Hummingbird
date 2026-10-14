#if DEBUG && os(iOS)
import Foundation
@preconcurrency import MetricKit

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
    private struct PendingHang: Sendable {
        let filename: String
        let data: Data
    }
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
        let hangs = payloads.compactMap { payload -> PendingHang? in
            guard !(payload.hangDiagnostics?.isEmpty ?? true),
                  let data = payload.jsonRepresentation() else { return nil }
            let begin = Int(payload.timeStampBegin.timeIntervalSince1970)
            let end = Int(payload.timeStampEnd.timeIntervalSince1970)
            return PendingHang(filename: "hang-\(begin)-\(end).json", data: data)
        }
        guard !hangs.isEmpty else { return }
        writer.async {
            do {
                let directory = try Self.directory()
                for hang in hangs {
                    let url = directory.appendingPathComponent(hang.filename)
                    try hang.data.write(to: url, options: .atomic)
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
