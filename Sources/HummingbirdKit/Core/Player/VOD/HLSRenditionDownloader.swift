import Foundation
import os

/// Builds the upstream request for any URL of a presentation (playlists,
/// keys, segments) and an optional byte range, through the plugin's request
/// modifier when the source has one.
struct UpstreamURLSigner: Sendable {
    let sign: @Sendable (URL, Range<Int64>?) async throws -> URLRequest

    init(_ sign: @escaping @Sendable (URL, Range<Int64>?) async throws -> URLRequest) {
        self.sign = sign
    }

    static func plain(headers: [String: String] = [:]) -> UpstreamURLSigner {
        UpstreamURLSigner { url, range in
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
            return request
        }
    }
}

/// Downloads every resource of one HLS media playlist (initialization maps,
/// keys and segments) into the media cache: maps and keys first, then
/// segments from the one the player needs onward, several at a time,
/// retrying with backoff while wanted and refreshing the playlist when its
/// URLs expire. Each resource is one cache entry, so a download resumes and a
/// finished presentation plays offline.
///
/// Its pipeline state counts in segments: "byte" ranges are segment ordinals
/// and the timeline maps each ordinal to its media time.
actor HLSRenditionDownloader {
    let role: MediaTrackRole
    private let cache: MediaCache
    private let identity: String
    private var resources: [HLSPlaylist.Resource]
    private let segments: [HLSPlaylist.Segment]
    private var signer: UpstreamURLSigner
    private let refresh: (@Sendable () async throws -> (UpstreamURLSigner, [HLSPlaylist.Resource]))?
    private let transport: any MediaTransport
    private let retry: DownloadRetryPolicy
    private let concurrency: Int

    private var done = Set<Int>()
    private var inFlight = Set<Int>()
    private var priorityOrdinal = 0
    private var condition: MediaStageCondition = .starting
    private var waiters: [UUID: (resource: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var observers: [UUID: @Sendable (MediaTrackPipelineState) -> Void] = [:]
    private var driver: Task<Void, Never>?
    private var refreshTask: Task<Void, Error>?
    private var stopped = false
    private let timeline: MediaSegmentTimeline
    private let scheduler: DownloadScheduler?
    private(set) var priority: DownloadPriority = .foreground
    private var finishHandler: (@Sendable () async -> Void)?
    private(set) var isFinished = false
    var isStopped: Bool { stopped }
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        isPaused = paused
        condition = paused ? .paused : (condition == .paused ? .running : condition)
        publish()
    }

    /// Every cache entry this rendition uses (to remove a download).
    var cacheIdentities: [String] { resources.indices.map { key($0) } }

    init(role: MediaTrackRole, cache: MediaCache, identity: String, media: HLSPlaylist.Media,
         signer: UpstreamURLSigner,
         refresh: (@Sendable () async throws -> (UpstreamURLSigner, [HLSPlaylist.Resource]))?,
         transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession),
         retry: DownloadRetryPolicy = DownloadRetryPolicy(), concurrency: Int = 4,
         scheduler: DownloadScheduler? = nil) {
        self.scheduler = scheduler
        self.role = role
        self.cache = cache
        self.identity = identity
        resources = media.resources
        segments = media.segments
        self.signer = signer
        self.refresh = refresh
        self.transport = transport
        self.retry = retry
        self.concurrency = concurrency
        var start = 0.0
        timeline = MediaSegmentTimeline(initialization: 0..<0, segments: media.segments.enumerated().map { ordinal, segment in
            defer { start += segment.duration }
            return .init(bytes: Int64(ordinal)..<Int64(ordinal + 1), start: start, duration: segment.duration)
        })
    }

    func setPriority(_ priority: DownloadPriority) { self.priority = priority }

    func onFinish(_ handler: @escaping @Sendable () async -> Void) { finishHandler = handler }

    func start() {
        guard driver == nil, !stopped else { return }
        driver = Task { await self.run() }
    }

    func stop() {
        stopped = true
        driver?.cancel()
        driver = nil
        refreshTask?.cancel()
        for (_, waiter) in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        waiters.removeAll()
        observers.removeAll()
    }

    func observe(_ handler: @escaping @Sendable (MediaTrackPipelineState) -> Void) {
        observers[UUID()] = handler
        handler(state)
    }

    var state: MediaTrackPipelineState {
        var completed = MediaRangeSet()
        var busy = MediaRangeSet()
        for (ordinal, segment) in segments.enumerated() {
            if done.contains(segment.resource) { completed.insert(Int64(ordinal)..<Int64(ordinal + 1)) }
            if inFlight.contains(segment.resource) { busy.insert(Int64(ordinal)..<Int64(ordinal + 1)) }
        }
        return MediaTrackPipelineState(role: role, totalBytes: Int64(segments.count), timeline: timeline,
                                       declaredDuration: timeline.duration,
                                       stages: [.download: MediaStageState(condition: condition, completed: completed, inFlight: busy)])
    }

    /// Waits until resource `index` is cached, fetching it next.
    func waitForResource(_ index: Int) async throws {
        if done.contains(index) { return }
        if stopped { throw CancellationError() }
        if let ordinal = segments.firstIndex(where: { $0.resource == index }) { priorityOrdinal = ordinal }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if done.contains(index) { continuation.resume() } else { waiters[id] = (index, continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func readResource(_ index: Int) async throws -> Data {
        let track = try await cache.open(identity: key(index))
        defer { Task { await self.cache.close(track) } }
        guard let total = await cache.totalBytes(track), let data = try await cache.read(track, range: 0..<total) else {
            throw TrackDownloadError.unexpectedResponse("cache lost a segment")
        }
        return data
    }

    func contentType(of index: Int) -> String {
        resources[index].kind == .key ? "application/octet-stream"
            : resources[index].uri.pathExtension.lowercased() == "ts" ? "video/mp2t" : "video/mp4"
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func key(_ index: Int) -> String { "\(identity)|resource-\(index)" }

    // MARK: driver

    private func run() async {
        // What earlier sessions already downloaded.
        for index in resources.indices {
            guard let track = try? await cache.open(identity: key(index)) else { continue }
            if let total = await cache.totalBytes(track), await cache.completed(track).contains(0..<total) {
                done.insert(index)
            }
            await cache.close(track)
        }
        resumeWaiters()
        condition = .running
        publish()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var running = 0
                while true {
                    try Task.checkCancellation()
                    while running < concurrency, let next = nextResource() {
                        inFlight.insert(next)
                        running += 1
                        group.addTask { try await self.fetchWithRetry(next) }
                    }
                    publish()
                    if running == 0 {
                        guard isPaused else { break }
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    _ = try await group.next()
                    running -= 1
                }
            }
            condition = .complete
            publish()
            OSSignposter.mediaCache.emitEvent("VODTrackComplete", "role=\(self.role.rawValue, privacy: .public) hls=true")
        } catch is CancellationError {
            return
        } catch {
            condition = .failed(error.localizedDescription)
            publish()
        }
        isFinished = true
        if let finishHandler { await finishHandler() }
    }

    /// Maps and keys first, then segments from the priority ordinal onward.
    private func nextResource() -> Int? {
        guard !isPaused else { return nil }
        let busy = done.union(inFlight)
        if let pending = resources.indices.first(where: { resources[$0].kind != .segment && !busy.contains($0) }) {
            return pending
        }
        let ordinals = Array(priorityOrdinal..<segments.count) + Array(0..<min(priorityOrdinal, segments.count))
        return ordinals.lazy.map { self.segments[$0].resource }.first { !busy.contains($0) }
    }

    private func fetchWithRetry(_ index: Int) async throws {
        defer { inFlight.remove(index) }
        var attempt = 0
        var refusals = 0
        while true {
            try Task.checkCancellation()
            do {
                try await fetch(index)
                if case .waitingForNetwork = condition { condition = .running }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                let status = (error as? HTTPStatusError)?.status
                if let status, DownloadRetryPolicy.classify(status: status) == .refresh {
                    refusals += 1
                    if refusals >= retry.refusalsBeforeRefresh, refresh != nil {
                        condition = .refreshingSource
                        publish()
                        if (try? await refreshed()) != nil { refusals = 0; continue }
                    }
                }
                let delay = retry.delay(afterAttempt: attempt)
                condition = .waitingForNetwork(retryAt: Date().addingTimeInterval(delay), attempt: attempt,
                                               reason: status.map { "http \($0)" } ?? String(describing: type(of: error)))
                publish()
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private struct HTTPStatusError: Error { let status: Int }

    private func fetch(_ index: Int) async throws {
        let resource = resources[index]
        let request = try await signer.sign(resource.uri, resource.byteRange)
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
        guard let http = response as? HTTPURLResponse else { throw TrackDownloadError.unexpectedResponse("no http response") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }
        var body = data
        if let range = resource.byteRange, http.statusCode == 200, data.count > range.count {
            // The server ignored the range: keep only the part the playlist names.
            guard data.count >= Int(range.upperBound) else { throw TrackDownloadError.unexpectedResponse("short body") }
            body = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        guard !body.isEmpty else { throw TrackDownloadError.unexpectedResponse("empty body") }
        let track = try await cache.open(identity: key(index))
        do {
            try await cache.reset(track)
            try await cache.writeMakingRoom(body, at: 0, to: track)
            try await cache.setTotalBytes(track, Int64(body.count))
        } catch {
            await cache.close(track)
            throw error
        }
        await cache.close(track)
        done.insert(index)
        resumeWaiters()
        publish()
    }

    private func refreshed() async throws {
        if let refreshTask { return try await refreshTask.value }
        guard let refresh else { return }
        let task = Task {
            let (newSigner, newResources) = try await refresh()
            guard newResources.count == self.resources.count else {
                throw TrackDownloadError.unexpectedResponse("the refreshed playlist differs")
            }
            self.apply(newSigner, newResources)
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func apply(_ newSigner: UpstreamURLSigner, _ newResources: [HLSPlaylist.Resource]) {
        signer = newSigner
        resources = newResources
    }

    private func resumeWaiters() {
        for (id, waiter) in waiters where done.contains(waiter.resource) {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    private func publish() {
        let snapshot = state
        for observer in observers.values { observer(snapshot) }
    }
}
