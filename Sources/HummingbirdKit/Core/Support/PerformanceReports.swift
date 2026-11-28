import Foundation
import os
import PlatformSupport

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

    /// A diagnostic the system reported.
    init(_ diagnostic: SystemPerformanceDiagnostic) {
        let kind: Kind = switch diagnostic.kind {
        case .crash: .crash
        case .hang: .hang
        case .cpuException: .cpuException
        case .diskWriteException: .diskWriteException
        }
        self.init(kind: kind, applicationBuild: diagnostic.applicationBuild, milliseconds: diagnostic.milliseconds,
                  bytes: diagnostic.bytes, signal: diagnostic.signal)
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
    /// Payloads older than this are dropped, whatever the other limits allow.
    public let maximumAge: TimeInterval

    public init(cachesDirectory: URL, maximumFiles: Int = 30, maximumBytes: Int = 8 * 1024 * 1024,
                maximumAge: TimeInterval = 30 * 24 * 60 * 60) {
        directory = cachesDirectory.appendingPathComponent("MetricKit", isDirectory: true)
        self.maximumFiles = maximumFiles
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
    }

    /// Stores one payload as `<kind>-<end>-<begin>.json`, then drops the
    /// oldest files beyond the limits.
    @discardableResult
    public func write(_ json: Data, kind: String, begin: Date, end: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(kind)-\(Int(end.timeIntervalSince1970))-\(Int(begin.timeIntervalSince1970)).json"
        let url = directory.appendingPathComponent(name)
        try AtomicFile.write(json, to: url)
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

    /// Main-thread stalls the debug-build watchdog recorded on this device.
    public var stallLog: StallLog { StallLog(cachesDirectory: directory.deletingLastPathComponent()) }

    /// One JSON file holding every stored payload and recorded stall, for
    /// sharing: `{"reports": [{"file": name, "payload": {...}}, ...],
    /// "stalls": [{"date": ..., "milliseconds": ..., "context": {...}}, ...]}`.
    /// Reads and writes files, so it runs off the caller's actor.
    @concurrent
    public func exportBundle(to destination: URL) async throws -> URL? {
        let reports = reports()
        let stalls = await stallLog.records()
        guard !reports.isEmpty || !stalls.isEmpty else { return nil }
        var entries: [[String: Any]] = []
        for url in reports {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) else { continue }
            entries.append(["file": url.lastPathComponent, "payload": payload])
        }
        let stallEntries: [[String: Any]] = stalls.map { record in
            [
                "date": ISO8601DateFormatter().string(from: record.date),
                "milliseconds": record.milliseconds,
                "context": record.context,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["reports": entries, "stalls": stallEntries], options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent("Hummingbird performance reports.json")
        try AtomicFile.write(data, to: url)
        return url
    }

    /// Deletes every stored payload, the recorded stalls and the export built
    /// in `exportDirectory`. Runs off the caller's actor; afterwards the
    /// export reports nothing.
    @concurrent
    public func clear(exportDirectory: URL) async throws {
        for url in reports() { try FileManager.default.removeItem(at: url) }
        await stallLog.clear()
        if FileManager.default.fileExists(atPath: exportDirectory.path) {
            try FileManager.default.removeItem(at: exportDirectory)
        }
    }

    /// Drops payloads beyond the file count, the byte budget (newest kept
    /// first) or older than `maximumAge`.
    func prune(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var total = 0
        for (index, url) in reports().enumerated() {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if index >= maximumFiles || total > maximumBytes || modified < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Main-thread stalls recorded by the debug-build watchdog
/// (`MainThreadWatchdog`), in `<caches>/Stalls/stalls.json`: the newest
/// `maximumRecords`, none older than `maximumAge`. Exported with the MetricKit
/// reports, so a device's stalls can be shared without log tooling. Writes
/// happen in order on a background queue.
public struct StallLog: Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var date: Date
        public var milliseconds: Int
        /// What the app was doing (active tab, route, player state).
        public var context: [String: String]
    }

    public let fileURL: URL
    public let maximumRecords: Int
    public let maximumAge: TimeInterval
    private static let writer = DispatchQueue(label: "com.eightybps.hummingbird.stall-log", qos: .utility)

    public init(cachesDirectory: URL, maximumRecords: Int = 500, maximumAge: TimeInterval = 7 * 24 * 60 * 60) {
        fileURL = cachesDirectory.appendingPathComponent("Stalls", isDirectory: true)
            .appendingPathComponent("stalls.json")
        self.maximumRecords = maximumRecords
        self.maximumAge = maximumAge
    }

    /// Queues `record`; returns at once.
    public func append(_ record: Record) {
        Self.writer.async { [self] in
            var records = load()
            records.append(record)
            store(records)
        }
    }

    /// Deletes every recorded stall, after the writes queued so far.
    public func clear() async {
        await withCheckedContinuation { continuation in
            Self.writer.async {
                try? FileManager.default.removeItem(at: fileURL)
                continuation.resume()
            }
        }
    }

    /// Waits until every record appended so far is written.
    public func flush() async {
        await withCheckedContinuation { continuation in
            Self.writer.async { continuation.resume() }
        }
    }

    /// Recorded stalls within the limits, oldest first. Reads and decodes the
    /// file after every queued write, off the caller's actor: the main actor
    /// cannot block on it.
    @concurrent
    public func records() async -> [Record] {
        await withCheckedContinuation { continuation in
            Self.writer.async { continuation.resume(returning: bounded(load())) }
        }
    }

    private func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    private func store(_ records: [Record]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(bounded(records)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? AtomicFile.write(data, to: fileURL)
    }

    private func bounded(_ records: [Record]) -> [Record] {
        let cutoff = Date().addingTimeInterval(-maximumAge)
        return Array(records.filter { $0.date >= cutoff }.suffix(maximumRecords))
    }
}

/// Receives the system's performance reports (SwiftOpenUI's
/// `SystemPerformanceReports`: MetricKit, or on Linux crashes recorded by
/// systemd-coredump): logs a privacy-safe line per diagnostic and keeps the
/// JSON in a `PerformanceReportStore`.
public final class PerformanceReporter: Sendable {
    private let store: PerformanceReportStore
    /// File writes stay off MetricKit's delivery thread.
    private let writer = DispatchQueue(label: "com.eightybps.hummingbird.performance-reports", qos: .utility)

    public init(store: PerformanceReportStore) {
        self.store = store
    }

    /// Subscribes to the system's reports. They arrive later, typically on
    /// the next launch (crashes) or at most once a day (metrics).
    public func start() {
        SystemPerformanceReports.subscribe { [self] payload in receive(payload) }
    }

    func receive(_ payload: SystemPerformancePayload) {
        switch payload {
        case .diagnostics(let diagnostics, let json, let begin, let end):
            record(diagnostics.map { PerformanceDiagnostic($0) }, json: json, begin: begin, end: end)
        case .metrics(let version, let multipleVersions, let json, let begin, let end):
            Logger.performance.info(
                "metrickit_metrics version=\(version, privacy: .public) multipleVersions=\(multipleVersions)"
            )
            store(json, kind: "metrics", begin: begin, end: end)
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

}

/// The process's MetricKit subscription, started once at launch by each
/// entry point (the Apple app and the GTK executable). A no-op where the system
/// delivers no reports (tvOS).
@MainActor
public enum PerformanceReports {
    private static var reporter: PerformanceReporter?

    /// Subscribes to MetricKit, storing payloads under `stores.cachesDirectory`.
    public static func start(stores: AppDataStores) {
        guard reporter == nil, SystemPerformanceReports.isAvailable else { return }
        let reporter = PerformanceReporter(store: PerformanceReportStore(cachesDirectory: stores.cachesDirectory))
        self.reporter = reporter
        reporter.start()
    }

    /// Where stored payloads are, for the Settings export.
    public static func store(for stores: AppDataStores) -> PerformanceReportStore {
        PerformanceReportStore(cachesDirectory: stores.cachesDirectory)
    }
}
