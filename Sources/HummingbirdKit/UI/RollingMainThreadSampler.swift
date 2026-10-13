#if DEBUG && os(iOS)
import CMainThreadSampler
import Darwin
import DebugKit
import Foundation

/// Keeps a short, low-frequency history of main-thread stacks and writes it
/// only when the display-link monitor observes a visible stall.
@MainActor
public enum RollingMainThreadSampler {
    public static func start() {
        MainThreadSampleRecorder.shared.start()
    }

    static func recordStall(gap: TimeInterval, context: [String: String]) {
        MainThreadSampleRecorder.shared.recordStall(gap: gap, context: context)
    }
}

private final class MainThreadSampleRecorder: @unchecked Sendable {
    @MainActor static let shared = MainThreadSampleRecorder()
    private struct Sample {
        let time: Date
        let addresses: [UInt64]
    }

    private let queue = DispatchQueue(label: "app.hummingbird.main-thread-sampler", qos: .utility)
    private let launchID = UUID().uuidString
    private var samples: [Sample] = []
    private var timer: DispatchSourceTimer?

    @MainActor
    func start() {
        guard timer == nil else { return }
        hb_sampler_set_main_thread()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    @MainActor
    func recordStall(gap: TimeInterval, context: [String: String]) {
        let detected = Date()
        queue.async { [weak self] in self?.writeCapture(gap: gap, detected: detected, context: context) }
    }

    private func sample() {
        var storage = [UInt64](repeating: 0, count: 96)
        let count = storage.withUnsafeMutableBufferPointer {
            hb_sampler_capture($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return }
        samples.append(Sample(time: Date(), addresses: Array(storage.prefix(Int(count)))))
        let cutoff = Date().addingTimeInterval(-15)
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
    }

    private func writeCapture(gap: TimeInterval, detected: Date, context: [String: String]) {
        let snapshot = samples
        let frames = snapshot.map { sample in
            [
                "time": Self.timestamp(sample.time),
                "frames": sample.addresses.map(Self.describe),
            ] as [String: Any]
        }
        let payload: [String: Any] = [
            "launchID": launchID,
            "detectedAt": Self.timestamp(detected),
            "gapMilliseconds": Int((gap * 1_000).rounded()),
            "context": context,
            "samples": frames,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            let directory = try DiagnosticsDirectories.sampler()
            let filename = "stall-\(Int(detected.timeIntervalSince1970 * 1_000)).json"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            // Profiling must never change application behavior.
        }
    }

    private static func describe(_ address: UInt64) -> [String: Any] {
        var info = Dl_info()
        let pointer = UnsafeRawPointer(bitPattern: UInt(address))
        guard let pointer, dladdr(pointer, &info) != 0 else { return ["address": address] }
        let imageBase = UInt64(UInt(bitPattern: info.dli_fbase))
        let symbolAddress = UInt64(UInt(bitPattern: info.dli_saddr))
        var result: [String: Any] = [
            "address": address,
            "image": info.dli_fname.map { String(cString: $0) } ?? "",
            "imageBase": imageBase,
            "imageOffset": address >= imageBase ? address - imageBase : 0,
        ]
        if let symbol = info.dli_sname {
            result["symbol"] = String(cString: symbol)
            result["symbolOffset"] = address >= symbolAddress ? address - symbolAddress : 0
        }
        return result
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

enum DiagnosticsDirectories {
    static func root() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let root = caches.appendingPathComponent("Hummingbird", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func sampler() throws -> URL {
        let directory = try root().appendingPathComponent("stall-samples", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
#endif
