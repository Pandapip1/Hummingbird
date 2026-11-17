import Foundation
@testable import HummingbirdKit

/// An in-process network conditioner for the playback harness: it sits
/// between the media downloads and the real upstream (`MediaTransport`), so
/// nothing system-wide changes. It models a shared link (bandwidth cap),
/// latency with jitter, request failures (loss), connection stalls (bytes stop
/// without an error: the request's idle timeout decides), mid-transfer resets,
/// total outages, and a network change (every connection resets, and URLs
/// issued before it are refused with 403 as YouTube refuses a URL bound to
/// the old address).
///
/// Plugin HTTP (details, signing) is not conditioned here.
struct NetworkProfile: Sendable {
    var name: String
    /// Bits per second; nil: unlimited.
    var bandwidth: Double?
    var latency: Double = 0
    var jitter: Double = 0
    /// Probability a request fails outright (packet-loss-like).
    var failureRate: Double = 0
    /// Probability a request stalls, and for how long (seconds).
    var stallRate: Double = 0
    var stallSeconds: ClosedRange<Double> = 2...8
    /// Probability a transfer is reset part-way.
    var resetRate: Double = 0
    /// Extra latency on a request that needs a new connection (DNS).
    var connectionLatency: Double = 0
    /// Total outages: (start, length) in seconds since the profile started.
    var outages: [(start: Double, length: Double)] = []
    /// A network change at this time, then the profile continues as `after`.
    var change: (at: Double, after: Box)? = nil

    final class Box: Sendable {
        let profile: NetworkProfile
        init(_ profile: NetworkProfile) { self.profile = profile }
    }

    static let all: [String: NetworkProfile] = {
        let cellular = NetworkProfile(name: "cellular", bandwidth: 5_000_000, latency: 0.1, jitter: 0.05)
        return [
            "none": NetworkProfile(name: "none"),
            "lte": NetworkProfile(name: "lte", bandwidth: 50_000_000, latency: 0.065, jitter: 0.02),
            "3g": NetworkProfile(name: "3g", bandwidth: 780_000, latency: 0.1, jitter: 0.03),
            "edge": NetworkProfile(name: "edge", bandwidth: 240_000, latency: 0.4, jitter: 0.1),
            "dsl": NetworkProfile(name: "dsl", bandwidth: 2_000_000, latency: 0.005),
            "very-bad": NetworkProfile(name: "very-bad", bandwidth: 1_000_000, latency: 0.5, jitter: 0.2,
                                       failureRate: 0.1, resetRate: 0.05, outages: [(90, 20)]),
            "high-latency-dns": NetworkProfile(name: "high-latency-dns", connectionLatency: 3),
            "flaky-wifi": NetworkProfile(name: "flaky-wifi", bandwidth: 30_000_000, latency: 0.01, jitter: 0.01,
                                         stallRate: 0.15, stallSeconds: 2...8),
            "handoff": NetworkProfile(name: "handoff", bandwidth: 30_000_000, latency: 0.01,
                                      change: (at: 120, after: Box(cellular))),
        ]
    }()
}

actor NetworkConditioner: MediaTransport {
    private let base: any MediaTransport
    private var profile: NetworkProfile
    private let started = ContinuousClock.now
    /// When the shared link is next free (bandwidth cap).
    private var linkFreeAt = ContinuousClock.now
    private var connectedHosts: Set<String> = []
    private var changed = false
    /// URLs seen before the network change: refused after it.
    private var urlsBeforeChange: Set<String> = []
    private var changeGeneration = 0
    private(set) var events: [String] = []

    init(base: any MediaTransport, profile: NetworkProfile) {
        self.base = base
        self.profile = profile
    }

    private var elapsed: Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func log(_ event: String) {
        let line = String(format: "[net] t=%7.1f %@", elapsed, event)
        events.append(line)
        print(line)
    }

    private func sleep(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        applyNetworkChangeIfDue()
        let generation = changeGeneration
        let url = request.url
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 60

        // Outage: no route.
        if profile.outages.contains(where: { elapsed >= $0.start && elapsed < $0.start + $0.length }) {
            try await sleep(min(timeout, 1))
            log("outage request failed")
            throw URLError(.notConnectedToInternet)
        }
        // After a network change, URLs bound to the old address are refused.
        if changed, urlsBeforeChange.contains(signatureKey(url)) {
            log("403 for a URL issued before the network change")
            return (Data(), HTTPURLResponse(url: url ?? URL(fileURLWithPath: "/"), statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        if !changed { urlsBeforeChange.insert(signatureKey(url)) }

        // Latency (+ DNS for a new connection).
        var latency = profile.latency + Double.random(in: -profile.jitter...max(profile.jitter, 0))
        if let host = url?.host, profile.connectionLatency > 0, !connectedHosts.contains(host) || Double.random(in: 0..<1) < 0.05 {
            connectedHosts.insert(host)
            latency += profile.connectionLatency
            log("new connection: +\(profile.connectionLatency) s")
        }
        try await sleep(max(0, latency))
        if Double.random(in: 0..<1) < profile.failureRate {
            log("request lost")
            throw URLError(.networkConnectionLost)
        }

        let (data, response) = try await base.data(for: request)
        if generation != changeGeneration { log("reset by network change"); throw URLError(.networkConnectionLost) }

        // Stall: bytes stop without an error; the idle timeout decides.
        if Double.random(in: 0..<1) < profile.stallRate {
            let stall = Double.random(in: profile.stallSeconds)
            if stall >= timeout {
                log(String(format: "stall %.1f s >= idle timeout %.0f s: timed out", stall, timeout))
                try await sleep(timeout)
                throw URLError(.timedOut)
            }
            log(String(format: "stall %.1f s", stall))
            try await sleep(stall)
        }
        // Shared link: this transfer takes its share of the bandwidth.
        if let bandwidth = profile.bandwidth {
            let seconds = Double(data.count * 8) / bandwidth
            let now = ContinuousClock.now
            let start = max(now, linkFreeAt)
            let finish = start.advanced(by: .milliseconds(Int(seconds * 1_000)))
            linkFreeAt = finish
            let wait = now.duration(to: finish)
            if Double.random(in: 0..<1) < profile.resetRate {
                try await Task.sleep(for: wait / 2)
                log("reset mid-transfer")
                throw URLError(.networkConnectionLost)
            }
            try await Task.sleep(for: wait)
        } else if Double.random(in: 0..<1) < profile.resetRate {
            log("reset mid-transfer")
            throw URLError(.networkConnectionLost)
        }
        if generation != changeGeneration { log("reset by network change"); throw URLError(.networkConnectionLost) }
        return (data, response)
    }

    /// The signed part of a URL: its query identifies the address it was issued for.
    private func signatureKey(_ url: URL?) -> String {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        let stable = (components.queryItems ?? []).filter { !["range", "rn", "rbuf"].contains($0.name) }
        return (components.host ?? "") + (components.path) + stable.map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
    }

    private func applyNetworkChangeIfDue() {
        guard !changed, let change = profile.change, elapsed >= change.at else { return }
        changed = true
        changeGeneration += 1
        connectedHosts.removeAll()
        let after = change.after.profile
        log("network change -> \(after.name): connections reset, old URLs refused")
        var next = after
        next.outages = profile.outages
        profile = next
    }
}
