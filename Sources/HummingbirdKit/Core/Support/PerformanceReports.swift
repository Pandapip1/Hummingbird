import Foundation
import os
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// What a MetricKit diagnostic says, reduced to values that are safe to log
/// in public: kinds, build numbers, signals, durations and sizes. Call stacks
/// and termination reasons stay in the stored payload.
public struct PerformanceDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case crash, hang, cpuException = "cpu-exception", diskWriteException = "disk-write-exception"
    }

    public let kind: Kind
    public let applicationBuild: String
    /// Hang duration, or CPU time for a CPU exception, in milliseconds.
    public let milliseconds: Int?
    /// Bytes written, for a disk-write exception.
    public let bytes: Int?
    /// The signal, for a crash.
    public let signal: Int?

    public init(kind: Kind, applicationBuild: String, milliseconds: Int? = nil, bytes: Int? = nil, signal: Int? = nil) {
        self.kind = kind
        self.applicationBuild = applicationBuild
        self.milliseconds = milliseconds
        self.bytes = bytes
        self.signal = signal
    }

    /// Writes one unified-logging entry: crashes as faults, the rest as errors.
    func log() {
        switch kind {
        case .crash:
            Logger.performance.fault(
                "metrickit_crash build=\(applicationBuild, privacy: .public) signal=\(signal ?? -1)"
            )
        case .hang:
            Logger.performance.error(
                "metrickit_hang build=\(applicationBuild, privacy: .public) ms=\(milliseconds ?? -1)"
            )
        case .cpuException:
            Logger.performance.error(
                "metrickit_cpu_exception build=\(applicationBuild, privacy: .public) cpu_ms=\(milliseconds ?? -1)"
            )
        case .diskWriteException:
            Logger.performance.error(
                "metrickit_disk_write_exception build=\(applicationBuild, privacy: .public) bytes=\(bytes ?? -1)"
            )
        }
    }
}

/// MetricKit payloads as JSON files in `<caches>/MetricKit`, newest kept.
///
/// MetricKit hands each payload to the app once; keeping the JSON lets a
/// developer or tester export it from Settings (or copy it out of the
/// container with `xcrun simctl get_app_container` / `devicectl`) and open it
/// next to the dSYMs. Nothing is uploaded anywhere.
public struct PerformanceReportStore: Sendable {
    public let directory: URL
    public let maximumFiles: Int
    public let maximumBytes: Int

    public init(cachesDirectory: URL, maximumFiles: Int = 30, maximumBytes: Int = 8 * 1024 * 1024) {
        directory = cachesDirectory.appendingPathComponent("MetricKit", isDirectory: true)
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
    }

    /// Stores one payload as `<kind>-<end>-<begin>.json`, then drops the
    /// oldest files beyond the limits.
    @discardableResult
    public func write(_ json: Data, kind: String, begin: Date, end: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(end.timeIntervalSince1970))-\(Int(begin.timeIntervalSince1970)).json"
        let url = directory.appendingPathComponent(name)
        try json.write(to: url, options: .atomic)
        try prune()
        return url
    }

    /// Stored payloads, newest first.
    public func reports() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? lhs.lastPathComponent > rhs.lastPathComponent : left > right
        }
    }

    /// One JSON file holding every stored payload, for sharing:
    /// `{"reports": [{"file": name, "payload": {...}}, ...]}`.
    public func exportBundle(to destination: URL) throws -> URL? {
        let reports = reports()
        guard !reports.isEmpty else { return nil }
        var entries: [[String: Any]] = []
        for url in reports {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) else { continue }
            entries.append(["file": url.lastPathComponent, "payload": payload])
        }
        let data = try JSONSerialization.data(withJSONObject: ["reports": entries], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent("Hummingbird performance reports.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func prune() throws {
        var total = 0
        for (index, url) in reports().enumerated() {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= maximumFiles || total > maximumBytes {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

#if canImport(MetricKit) && !os(tvOS)
/// Receives MetricKit payloads: logs a privacy-safe line per diagnostic and
/// keeps the JSON in a `PerformanceReportStore`. On Linux, SwiftOpenUI's
/// MetricKit delivers crashes recorded by systemd-coredump.
public final class PerformanceReporter: NSObject, MXMetricManagerSubscriber, Sendable {
    private let store: PerformanceReportStore
    /// File writes stay off MetricKit's delivery thread.
    private let writer = DispatchQueue(label: "com.eightybps.hummingbird.performance-reports", qos: .utility)

    public init(store: PerformanceReportStore) {
        self.store = store
    }

    /// Subscribes to MetricKit. Payloads arrive later, typically on the next
    /// launch (crashes) or at most once a day (metrics); in Xcode use
    /// Debug > Simulate MetricKit Payloads.
    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            record(
                Self.diagnostics(in: payload), json: payload.jsonRepresentation(),
                begin: payload.timeStampBegin, end: payload.timeStampEnd
            )
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Logger.performance.info(
                "metrickit_metrics version=\(payload.latestApplicationVersion, privacy: .public) multipleVersions=\(payload.includesMultipleApplicationVersions)"
            )
            store(payload.jsonRepresentation(), kind: "metrics", begin: payload.timeStampBegin, end: payload.timeStampEnd)
        }
    }

    /// Logs `diagnostics` and stores `json`. The payload-free entry point, so
    /// tests can feed stand-in payloads.
    func record(_ diagnostics: [PerformanceDiagnostic], json: Data, begin: Date, end: Date) {
        diagnostics.forEach { $0.log() }
        let kinds = Set(diagnostics.map(\.kind.rawValue)).sorted().joined(separator: "+")
        store(json, kind: kinds.isEmpty ? "diagnostic" : kinds, begin: begin, end: end)
    }

    /// Waits for pending writes; for tests.
    func flush() async {
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }

    private func store(_ json: Data, kind: String, begin: Date, end: Date) {
        let store = store
        writer.async {
            do {
                try store.write(json, kind: kind, begin: begin, end: end)
            } catch {
                Logger.performance.error("report_write_failed error=\(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
    }

    static func diagnostics(in payload: MXDiagnosticPayload) -> [PerformanceDiagnostic] {
        var result: [PerformanceDiagnostic] = []
        for crash in payload.crashDiagnostics ?? [] {
            result.append(PerformanceDiagnostic(
                kind: .crash, applicationBuild: crash.metaData.applicationBuildVersion,
                signal: crash.signal?.intValue
            ))
        }
        for hang in payload.hangDiagnostics ?? [] {
            result.append(PerformanceDiagnostic(
                kind: .hang, applicationBuild: hang.metaData.applicationBuildVersion,
                milliseconds: Int(hang.hangDuration.converted(to: .milliseconds).value)
            ))
        }
        for exception in payload.cpuExceptionDiagnostics ?? [] {
            result.append(PerformanceDiagnostic(
                kind: .cpuException, applicationBuild: exception.metaData.applicationBuildVersion,
                milliseconds: Int(exception.totalCPUTime.converted(to: .milliseconds).value)
            ))
        }
        for exception in payload.diskWriteExceptionDiagnostics ?? [] {
            result.append(PerformanceDiagnostic(
                kind: .diskWriteException, applicationBuild: exception.metaData.applicationBuildVersion,
                bytes: Int(exception.totalWritesCaused.converted(to: .bytes).value)
            ))
        }
        return result
    }
}

#endif

/// The process's MetricKit subscription, started once at launch by each
/// entry point (the Apple app and the GTK executable). A no-op where there is
/// no MetricKit (tvOS).
@MainActor
public enum PerformanceReports {
    #if canImport(MetricKit) && !os(tvOS)
    private static var reporter: PerformanceReporter?
    #endif

    /// Subscribes to MetricKit, storing payloads under `stores.cachesDirectory`.
    public static func start(stores: AppDataStores) {
        #if canImport(MetricKit) && !os(tvOS)
        guard reporter == nil else { return }
        let reporter = PerformanceReporter(store: PerformanceReportStore(cachesDirectory: stores.cachesDirectory))
        self.reporter = reporter
        reporter.start()
        #endif
    }

    /// Where stored payloads are, for the Settings export.
    public static func store(for stores: AppDataStores) -> PerformanceReportStore {
        PerformanceReportStore(cachesDirectory: stores.cachesDirectory)
    }
}
