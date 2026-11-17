import Foundation
import os

/// Records one rendition of a live HLS stream into the media cache and
/// serves it back as a growing (EVENT) playlist.
///
/// - Polls the upstream playlist every target duration (half that when it
///   did not change, as RFC 8216 §6.3.4 asks) and downloads each new
///   segment, map and key as soon as it appears: several at a time, the ones
///   the player waits for first, retried with backoff, with fresh URLs from
///   the plugin when they expire.
/// - The local playlist lists every segment recorded so far, so the player
///   can rewind past upstream's window; its live edge is upstream's newest
///   segment (the loopback server waits for its bytes). When upstream ends
///   (`EXT-X-ENDLIST`) the local playlist ends too and replays like a VOD.
/// - The recording's index is kept in the cache next to its segments, so
///   reopening the stream continues the same recording, and it is evicted
///   with the same limit and LRU as everything else.
/// - Discontinuities (ad breaks such as Twitch's, encoder restarts) are
///   kept. Low-latency HLS partial segments (`EXT-X-PART`, preload hints) are
///   ignored: whole segments only, so the live edge trails upstream's by up
///   to one segment.
/// - Nobody watching (background priority): recording continues, using only
///   bandwidth playback leaves idle, until the stream ends or the cache is
///   over its limit; the recording stays replayable.
actor LiveHLSRecorder {
    struct Segment: Codable, Sendable, Equatable {
        var sequence: Int
        var duration: Double
        var resource: String
        var map: String?
        var key: String?
        var keyAttributes: String?
        var discontinuity: Bool
        var programDateTime: String?
    }

    private struct Upstream: Codable, Sendable, Equatable {
        var url: URL
        var lower: Int64?
        var upper: Int64?
        var range: Range<Int64>? { lower.flatMap { l in upper.map { l..<$0 } } }
    }

    private struct Manifest: Codable {
        var segments: [Segment]
        var resources: [String: Upstream]
        var ended: Bool
        var targetDuration: Int
    }

    let role: MediaTrackRole
    private let cache: MediaCache
    private let identity: String
    private var playlistURL: URL
    private var signer: UpstreamURLSigner
    private let refresh: (@Sendable () async throws -> (UpstreamURLSigner, URL))?
    private let transport: any MediaTransport
    private let scheduler: DownloadScheduler?
    private let retry = DownloadRetryPolicy()
    private let concurrency: Int

    private var segments: [Segment] = []
    private var resources: [String: Upstream] = [:]
    private var ended = false
    private var targetDuration = 6
    private var done = Set<String>()
    private var inFlight = Set<String>()
    private var prioritySequence: Int?
    private(set) var priority: DownloadPriority = .foreground
    private var condition: MediaStageCondition = .starting
    private var waiters: [UUID: (resource: String, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var firstPollWaiters: [CheckedContinuation<Void, Error>] = []
    private var polledOnce = false
    private var observers: [UUID: @Sendable (MediaTrackPipelineState) -> Void] = [:]
    private var pollTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var stopped = false
    private var finishHandler: (@Sendable () async -> Void)?
    private(set) var isFinished = false
    var isStopped: Bool { stopped }
    private var stoppedForSpace = false
    /// Low-latency HLS: a recorded partial segment.
    private struct Part: Sendable, Equatable {
        var index: Int
        var duration: Double
        var resource: String
        var independent: Bool
    }
    private var partTarget: Double?
    private var canBlockReload = false
    /// Parts by media sequence number, in order; kept once their segment is
    /// complete (the local playlist lists them for the newest segments).
    private var parts: [Int: [Part]] = [:]

    /// The playlist URL, with `_HLS_msn`/`_HLS_part` asking upstream to hold
    /// the response until the next part exists, when it supports that.
    private func blockingReloadURL() -> URL {
        guard canBlockReload, partTarget != nil,
              var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false) else { return playlistURL }
        let publishing = (segments.last?.sequence ?? -1) + 1
        let nextPart = parts[publishing]?.count ?? 0
        var items = (components.queryItems ?? []).filter { $0.name != "_HLS_msn" && $0.name != "_HLS_part" }
        items.append(URLQueryItem(name: "_HLS_msn", value: String(publishing)))
        items.append(URLQueryItem(name: "_HLS_part", value: String(nextPart)))
        components.queryItems = items
        return components.url ?? playlistURL
    }
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        isPaused = paused
        condition = paused ? .paused : (condition == .paused ? .running : condition)
        publish()
    }

    /// Every cache entry this recording uses (to remove it).
    var cacheIdentities: [String] { resources.keys.map { key($0) } + ["\(identity)|live|manifest"] }
    private var lastSpaceCheck = ContinuousClock.now

    init(role: MediaTrackRole, cache: MediaCache, identity: String, playlistURL: URL, signer: UpstreamURLSigner,
         refresh: (@Sendable () async throws -> (UpstreamURLSigner, URL))?,
         transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession),
         scheduler: DownloadScheduler? = nil, concurrency: Int = 3) {
        self.role = role
        self.cache = cache
        self.identity = identity
        self.playlistURL = playlistURL
        self.signer = signer
        self.refresh = refresh
        self.transport = transport
        self.scheduler = scheduler
        self.concurrency = concurrency
    }

    // MARK: control

    func start() async {
        guard pollTask == nil, !stopped else { return }
        await loadManifest()
        pollTask = Task { await self.pollLoop() }
        fetchTask = Task { await self.fetchLoop() }
    }

    func stop() {
        stopped = true
        pollTask?.cancel()
        fetchTask?.cancel()
        for (_, waiter) in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        waiters.removeAll()
        for waiter in firstPollWaiters { waiter.resume(throwing: CancellationError()) }
        firstPollWaiters.removeAll()
        observers.removeAll()
    }

    /// Foreground while someone watches; background otherwise. Both keep
    /// recording; background yields the network to playback.
    func setPriority(_ priority: DownloadPriority) {
        self.priority = priority
        if pollTask == nil, !ended, !stopped, !stoppedForSpace {
            pollTask = Task { await self.pollLoop() }
        }
    }

    func onFinish(_ handler: @escaping @Sendable () async -> Void) { finishHandler = handler }

    func observe(_ handler: @escaping @Sendable (MediaTrackPipelineState) -> Void) {
        observers[UUID()] = handler
        handler(state)
    }

    /// Waits until the upstream playlist has been read once.
    func waitForFirstPoll() async throws {
        if polledOnce || !segments.isEmpty { return }
        if stopped { throw CancellationError() }
        try await withCheckedThrowingContinuation { firstPollWaiters.append($0) }
    }

    // MARK: serving

    /// The local playlist: every recorded segment with local URIs under `prefix/`.
    /// For a low-latency stream it is a low-latency playlist too: the recent
    /// segments' parts, the parts of the segment being published, a preload
    /// hint for the next part, and blocking reload (see `waitForPlaylist`).
    func localPlaylist(prefix: String) -> String {
        var out = "#EXTM3U\n#EXT-X-VERSION:9\n#EXT-X-TARGETDURATION:\(max(targetDuration, Int(ceil(segments.map(\.duration).max() ?? 1))))\n"
        if let partTarget, !ended {
            out += "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(String(format: "%.3f", partTarget * 3))\n"
            out += "#EXT-X-PART-INF:PART-TARGET=\(String(format: "%.3f", partTarget))\n"
        }
        out += "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? 0)\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
        // Parts are listed for the last few segments only, as upstream does.
        let partsFrom = (segments.last?.sequence ?? 0) - 2
        var currentMap: String?
        var currentKey: String??
        for segment in segments {
            if segment.discontinuity, segment.sequence != segments.first?.sequence { out += "#EXT-X-DISCONTINUITY\n" }
            if let map = segment.map, map != currentMap {
                out += "#EXT-X-MAP:URI=\"\(prefix)/\(map)\"\n"
                currentMap = map
            }
            if currentKey != .some(segment.key) {
                if let key = segment.key, let attributes = segment.keyAttributes {
                    let old = HLSPlaylist.attribute("URI", in: attributes) ?? ""
                    out += "#EXT-X-KEY:\(attributes.replacingOccurrences(of: "URI=\"\(old)\"", with: "URI=\"\(prefix)/\(key)\""))\n"
                } else if currentKey != nil {
                    out += "#EXT-X-KEY:METHOD=NONE\n"
                }
                currentKey = .some(segment.key)
            }
            if let date = segment.programDateTime { out += "#EXT-X-PROGRAM-DATE-TIME:\(date)\n" }
            if partTarget != nil, !ended, segment.sequence >= partsFrom {
                out += partLines(for: segment.sequence, prefix: prefix)
            }
            out += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n\(prefix)/\(segment.resource)\n"
        }
        if ended {
            out += "#EXT-X-ENDLIST\n"
        } else if partTarget != nil {
            // The segment being published: its parts so far, and the next one to come.
            let publishing = (segments.last?.sequence ?? -1) + 1
            out += partLines(for: publishing, prefix: prefix)
            out += "#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(prefix)/p\(publishing).\(parts[publishing]?.count ?? 0)\"\n"
        }
        return out
    }

    private func partLines(for sequence: Int, prefix: String) -> String {
        (parts[sequence] ?? []).map { part in
            "#EXT-X-PART:DURATION=\(String(format: "%.5f", part.duration)),URI=\"\(prefix)/\(part.resource)\"" + (part.independent ? ",INDEPENDENT=YES" : "") + "\n"
        }.joined()
    }

    /// Blocking playlist reload (`_HLS_msn`, `_HLS_part`): waits until the
    /// recording has segment `msn` (or its part `part`), at most three target
    /// durations, as RFC 8216bis asks of a server.
    func waitForPlaylist(msn: Int, part: Int?) async {
        func available() -> Bool {
            if ended { return true }
            if let part { return (parts[msn]?.count ?? 0) > part || (segments.last?.sequence ?? Int.min) >= msn }
            return (segments.last?.sequence ?? Int.min) >= msn
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(Double(max(targetDuration, 1) * 3)))
        while !available(), !stopped, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The parts recorded for `sequence` (tests, diagnostics).
    func partCount(for sequence: Int) -> Int { parts[sequence]?.count ?? 0 }

    func waitForResource(_ id: String) async throws {
        if done.contains(id) { return }
        if stopped { throw CancellationError() }
        // A preload hint names a part (or segment) upstream has not announced
        // yet: the request waits for it like for any other resource.
        guard resources[id] != nil || id.hasPrefix("p") || id.hasPrefix("s") else {
            throw TrackDownloadError.unexpectedResponse("unknown live resource")
        }
        if let segment = segments.first(where: { $0.resource == id }) { prioritySequence = segment.sequence }
        let waiter = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if done.contains(id) { continuation.resume() } else { waiters[waiter] = (id, continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiter) }
        }
    }

    func readResource(_ id: String) async throws -> Data {
        let track = try await cache.open(identity: key(id))
        var data: Data?
        if let total = await cache.totalBytes(track) { data = try await cache.read(track, range: 0..<total) }
        await cache.close(track)
        guard let data else { throw TrackDownloadError.unexpectedResponse("cache lost a live segment") }
        return data
    }

    func contentType(of id: String) -> String {
        if id.hasPrefix("k") { return "application/octet-stream" }
        return resources[id]?.url.pathExtension.lowercased() == "ts" ? "video/mp2t" : "video/mp4"
    }

    var state: MediaTrackPipelineState {
        var completed = MediaRangeSet()
        var busy = MediaRangeSet()
        var start = 0.0
        var timeline: [MediaSegmentTimeline.Segment] = []
        for (ordinal, segment) in segments.enumerated() {
            let unit = Int64(ordinal)..<Int64(ordinal + 1)
            timeline.append(.init(bytes: unit, start: start, duration: segment.duration))
            start += segment.duration
            if done.contains(segment.resource) { completed.insert(unit) }
            if inFlight.contains(segment.resource) { busy.insert(unit) }
        }
        let stage = MediaStageState(condition: condition, completed: completed, inFlight: busy)
        return MediaTrackPipelineState(role: role, totalBytes: Int64(segments.count),
                                       timeline: MediaSegmentTimeline(initialization: 0..<0, segments: timeline),
                                       declaredDuration: start, stages: [.download: stage])
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func key(_ id: String) -> String { "\(identity)|live|\(id)" }

    // MARK: polling

    private func pollLoop() async {
        defer { pollTask = nil }
        var attempt = 0
        var refusals = 0
        while !Task.isCancelled, !stopped, !ended, !stoppedForSpace {
            do {
                if priority == .background, lastSpaceCheck.duration(to: .now) > .seconds(30) {
                    lastSpaceCheck = .now
                    if await cache.isOverLimit() {
                        // The recording so far stays; it just stops growing.
                        stoppedForSpace = true
                        Logger.mediaCache.notice("live_recording_stopped reason=space")
                        return
                    }
                }
                let grew = try await poll()
                attempt = 0
                refusals = 0
                if canBlockReload {
                    // The next request blocks upstream until the next part exists.
                    continue
                }
                let interval = partTarget ?? Double(targetDuration)
                let wait = interval / (grew ? 1 : 2)
                try await Task.sleep(for: .seconds(max(partTarget == nil ? 1 : 0.1, wait)))
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                if let status = (error as? PlaylistStatus)?.status, DownloadRetryPolicy.classify(status: status) == .refresh {
                    refusals += 1
                    if refusals >= retry.refusalsBeforeRefresh, let refresh, let refreshed = try? await refresh() {
                        signer = refreshed.0
                        playlistURL = refreshed.1
                        refusals = 0
                        continue
                    }
                }
                condition = .waitingForNetwork(retryAt: Date().addingTimeInterval(retry.delay(afterAttempt: attempt)),
                                               attempt: attempt, reason: String(describing: type(of: error)))
                publish()
                try? await Task.sleep(for: .seconds(retry.delay(afterAttempt: attempt)))
            }
        }
    }

    private struct PlaylistStatus: Error { let status: Int }

    /// Reads the upstream playlist and appends what is new. Returns whether it grew.
    private func poll() async throws -> Bool {
        let request = try await signer.sign(blockingReloadURL(), nil)
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TrackDownloadError.unexpectedResponse("no http response") }
        guard (200..<300).contains(http.statusCode) else { throw PlaylistStatus(status: http.statusCode) }
        let media = try HLSPlaylist.parseMedia(String(decoding: data, as: UTF8.self), base: http.url ?? playlistURL)
        targetDuration = media.targetDuration
        partTarget = media.partTarget
        canBlockReload = media.canBlockReload && media.partTarget != nil
        let last = segments.last?.sequence ?? Int.min
        var grew = false
        // Low-latency parts, for complete segments and the one being published.
        for part in media.parts {
            let sequence = media.mediaSequence + part.segment
            guard sequence > last, (parts[sequence]?.count ?? 0) <= part.index else { continue }
            let id = "p\(sequence).\(part.index)"
            resources[id] = Upstream(url: part.uri, lower: part.byteRange?.lowerBound, upper: part.byteRange?.upperBound)
            parts[sequence, default: []].append(Part(index: part.index, duration: part.duration, resource: id,
                                                     independent: part.independent))
            grew = true
        }
        for (ordinal, segment) in media.segments.enumerated() {
            let sequence = media.mediaSequence + ordinal
            guard sequence > last else { continue }
            let resource = media.resources[segment.resource]
            let id = "s\(sequence)"
            resources[id] = Upstream(url: resource.uri, lower: resource.byteRange?.lowerBound, upper: resource.byteRange?.upperBound)
            segments.append(Segment(sequence: sequence, duration: segment.duration, resource: id,
                                    map: segment.map.map { register(media.resources[$0], prefix: "m") },
                                    key: segment.key.map { register(media.resources[$0], prefix: "k") },
                                    keyAttributes: segment.keyAttributes, discontinuity: segment.discontinuity,
                                    programDateTime: segment.programDateTime))
            grew = true
        }
        if !media.isEndless { ended = true }
        if prioritySequence == nil, let newest = segments.last?.sequence {
            // Start near the live edge, as the player will.
            prioritySequence = max(segments.first?.sequence ?? newest, newest - 3)
        }
        if condition != .running { condition = .running }
        if !polledOnce {
            polledOnce = true
            for waiter in firstPollWaiters { waiter.resume() }
            firstPollWaiters.removeAll()
        }
        if grew || ended { await saveManifest() }
        publish()
        return grew
    }

    /// Maps and keys get one id per distinct URL and range.
    private func register(_ resource: HLSPlaylist.Resource, prefix: String) -> String {
        let upstream = Upstream(url: resource.uri, lower: resource.byteRange?.lowerBound, upper: resource.byteRange?.upperBound)
        if let existing = resources.first(where: { $0.key.hasPrefix(prefix) && $0.value == upstream })?.key { return existing }
        let id = "\(prefix)\(resources.keys.filter { $0.hasPrefix(prefix) }.count)"
        resources[id] = upstream
        return id
    }

    // MARK: fetching

    private func fetchLoop() async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !Task.isCancelled, !stopped {
                while running < concurrency, let next = nextResource() {
                    inFlight.insert(next)
                    running += 1
                    group.addTask { await self.fetchWithRetry(next) }
                }
                publish()
                if running == 0 {
                    if (ended || stoppedForSpace), !isPaused {
                        if nextResource() == nil { break }
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                _ = await group.next()
                running -= 1
            }
        }
        guard !stopped else { return }
        condition = .complete
        publish()
        isFinished = true
        if let finishHandler { await finishHandler() }
    }

    /// Maps and keys first; then segments from the one the player wants (or
    /// the live edge) onward; then older ones, newest first.
    private func nextResource() -> String? {
        guard !isPaused else { return nil }
        let busy = done.union(inFlight)
        if let pending = resources.keys.sorted().first(where: { ($0.hasPrefix("m") || $0.hasPrefix("k")) && !busy.contains($0) }) {
            return pending
        }
        // Low latency: the newest parts of segments not yet complete come next,
        // so the player stays near the live edge.
        // A part is no longer needed once its whole segment is cached.
        for sequence in parts.keys.sorted(by: >) where !done.contains("s\(sequence)") {
            if let part = parts[sequence]?.first(where: { !busy.contains($0.resource) }) { return part.resource }
        }
        let pending = segments.filter { !busy.contains($0.resource) }
        guard !pending.isEmpty else { return nil }
        let from = prioritySequence ?? pending[0].sequence
        if let ahead = pending.first(where: { $0.sequence >= from }) { return ahead.resource }
        return pending.last?.resource
    }

    private func fetchWithRetry(_ id: String) async {
        defer { inFlight.remove(id) }
        var attempt = 0
        while !Task.isCancelled, !stopped {
            do {
                try await fetch(id)
                if case .waitingForNetwork = condition { condition = .running }
                return
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                let delay = retry.delay(afterAttempt: attempt)
                condition = .waitingForNetwork(retryAt: Date().addingTimeInterval(delay), attempt: attempt,
                                               reason: String(describing: type(of: error)))
                publish()
                if attempt % retry.refusalsBeforeRefresh == 0, let refresh, let refreshed = try? await refresh() {
                    // Fresh signing for the next attempt (expired query tokens).
                    signer = refreshed.0
                    playlistURL = refreshed.1
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func fetch(_ id: String) async throws {
        guard let upstream = resources[id] else { return }
        let request = try await signer.sign(upstream.url, upstream.range)
        let admitted = priority
        await scheduler?.admit(admitted)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
            await scheduler?.finish(admitted)
        } catch {
            await scheduler?.finish(admitted)
            throw error
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw TrackDownloadError.unexpectedResponse("live resource status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        var body = data
        if let range = upstream.range, http.statusCode == 200, data.count >= Int(range.upperBound) {
            body = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let track = try await cache.open(identity: key(id))
        do {
            try await cache.reset(track)
            try await cache.writeMakingRoom(body, at: 0, to: track)
            try await cache.setTotalBytes(track, Int64(body.count))
        } catch {
            await cache.close(track)
            throw error
        }
        await cache.close(track)
        done.insert(id)
        for (waiterID, waiter) in waiters where waiter.resource == id {
            waiters[waiterID] = nil
            waiter.continuation.resume()
        }
        publish()
    }

    // MARK: the recording's index

    private func loadManifest() async {
        guard let track = try? await cache.open(identity: "\(identity)|live|manifest") else { return }
        defer { Task { await self.cache.close(track) } }
        guard let total = await cache.totalBytes(track),
              let data = try? await cache.read(track, range: 0..<total),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        segments = manifest.segments
        resources = manifest.resources
        ended = manifest.ended
        targetDuration = manifest.targetDuration
        // Which recorded resources are already in the cache.
        for id in resources.keys {
            guard let entry = try? await cache.open(identity: key(id)) else { continue }
            if let size = await cache.totalBytes(entry), await cache.completed(entry).contains(0..<size) { done.insert(id) }
            await cache.close(entry)
        }
        if !segments.isEmpty { polledOnce = true }
        publish()
    }

    private func saveManifest() async {
        let manifest = Manifest(segments: segments, resources: resources, ended: ended, targetDuration: targetDuration)
        guard let data = try? JSONEncoder().encode(manifest),
              let track = try? await cache.open(identity: "\(identity)|live|manifest") else { return }
        try? await cache.reset(track)
        _ = try? await cache.writeMakingRoom(data, at: 0, to: track)
        try? await cache.setTotalBytes(track, Int64(data.count))
        await cache.close(track)
    }

    private func publish() {
        let snapshot = state
        for observer in observers.values { observer(snapshot) }
    }
}
