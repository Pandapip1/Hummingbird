import Foundation
import os

/// Produces the upstream request for a byte range of a track. For plugin
/// sources this runs the plugin's request modifier once per request, as
/// Grayjay does (YouTube's modifier moves the range into the URL and numbers
/// requests).
struct UpstreamRequestSigner: Sendable {
    let sign: @Sendable (Range<Int64>) async throws -> URLRequest

    init(_ sign: @escaping @Sendable (Range<Int64>) async throws -> URLRequest) {
        self.sign = sign
    }

    /// A plain URL, fetched with a `Range` header.
    static func plain(_ url: URL, headers: [String: String] = [:]) -> UpstreamRequestSigner {
        UpstreamRequestSigner { range in
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            return request
        }
    }
}

/// Fetches upstream bytes. `URLSessionTransport` in the app; tests inject failures.
protocol MediaTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: MediaTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Retry timing for failed downloads: exponential backoff with a cap, never
/// giving up while the download is wanted.
struct DownloadRetryPolicy: Sendable, Equatable {
    var initialDelay: Double = 0.5
    var maximumDelay: Double = 30
    /// After this many consecutive refusals (403/404/410) the source is refreshed.
    var refusalsBeforeRefresh = 2

    func delay(afterAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 0 }
        return min(maximumDelay, initialDelay * pow(2, Double(attempt - 1)))
    }

    enum Outcome: Equatable {
        /// Transient: wait and try again.
        case retry
        /// The upstream URL is no longer valid: refresh the source.
        case refresh
    }

    static func classify(status: Int) -> Outcome {
        switch status {
        case 401, 403, 404, 410: .refresh
        default: .retry
        }
    }
}

enum TrackDownloadError: Error, Equatable, LocalizedError {
    case unexpectedResponse(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse(let detail): "The media server sent an unexpected response (\(detail))."
        case .stopped: "The download stopped."
        }
    }
}

/// What the first bytes of a track revealed.
enum TrackLayout: Sendable, Equatable {
    /// Fragmented MP4 with a segment index: served as byte-range HLS.
    case indexed(FragmentedMP4.Layout)
    /// Any other file: served as a whole file with range requests.
    case progressive
}

/// Downloads one track completely into the media cache, as fast as the
/// network allows: several byte ranges in parallel, the ranges the player is
/// waiting for first, failed ranges retried with backoff for as long as the
/// download is wanted, and expired upstream URLs refreshed through the
/// plugin. Bytes already in the cache are never fetched again.
///
/// The player reads only through `waitUntilAvailable` + `read`: a network
/// failure makes a read wait (the player buffers), it never fails it.
actor TrackDownloader {
    struct Configuration: Sendable {
        var pieceBytes: Int64 = 2 * 1_024 * 1_024
        /// Pieces the player is waiting for are smaller, so playback starts sooner.
        var urgentPieceBytes: Int64 = 512 * 1_024
        var headerProbeBytes: Int64 = 256 * 1_024
        var concurrentPieces = 4
        var retry = DownloadRetryPolicy()
    }

    let role: MediaTrackRole
    private let cache: MediaCache
    private let track: MediaCache.TrackID
    private let transport: any MediaTransport
    private let configuration: Configuration
    private let indexHint: ClosedRange<Int64>?
    private var signer: UpstreamRequestSigner
    private let refreshSigner: (@Sendable () async throws -> UpstreamRequestSigner)?
    private var refreshTask: Task<UpstreamRequestSigner, Error>?
    private var consecutiveRefusals = 0

    private var completed = MediaRangeSet()
    private var inFlight = MediaRangeSet()
    private var totalBytes: Int64?
    private var condition: MediaStageCondition = .starting
    private var layout: TrackLayout?
    private var declaredDuration: Double?
    private var priorityOffset: Int64 = 0
    private var waiters: [UUID: (range: Range<Int64>, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var layoutWaiters: [UUID: CheckedContinuation<TrackLayout, Error>] = [:]
    private var observers: [UUID: @Sendable (MediaTrackPipelineState) -> Void] = [:]
    private var driver: Task<Void, Never>?
    private var stopped = false
    private var didResetForMismatch = false
    private let scheduler: DownloadScheduler?
    private(set) var priority: DownloadPriority = .foreground
    private var finishHandler: (@Sendable () async -> Void)?
    private(set) var isFinished = false
    private var lastSpaceCheck = ContinuousClock.now

    init(role: MediaTrackRole, cache: MediaCache, track: MediaCache.TrackID, signer: UpstreamRequestSigner,
         indexHint: ClosedRange<Int64>? = nil, declaredDuration: Double? = nil,
         refreshSigner: (@Sendable () async throws -> UpstreamRequestSigner)? = nil,
         transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession),
         scheduler: DownloadScheduler? = nil,
         configuration: Configuration = Configuration()) {
        self.role = role
        self.cache = cache
        self.track = track
        self.signer = signer
        self.indexHint = indexHint
        self.declaredDuration = declaredDuration
        self.refreshSigner = refreshSigner
        self.transport = transport
        self.scheduler = scheduler
        self.configuration = configuration
    }

    /// One session for every VOD download: no cookies, no HTTP cache (the
    /// media cache is the cache), enough connections for parallel ranges.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        // Idle timeout per request; a stalled range is retried rather than waited on.
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    // MARK: control

    /// Foreground while something plays the track; background otherwise (see `DownloadScheduler`).
    func setPriority(_ priority: DownloadPriority) {
        self.priority = priority
    }

    /// Called once when the download ends: complete, failed, or stopped for space.
    func onFinish(_ handler: @escaping @Sendable () async -> Void) {
        finishHandler = handler
    }

    func start() {
        guard driver == nil, !stopped else { return }
        driver = Task { [weak self] in await self?.run() }
    }

    /// Stops downloading. Everything already downloaded stays cached.
    func stop() async {
        stopped = true
        driver?.cancel()
        driver = nil
        refreshTask?.cancel()
        for (_, waiter) in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        waiters.removeAll()
        for (_, waiter) in layoutWaiters { waiter.resume(throwing: CancellationError()) }
        layoutWaiters.removeAll()
        observers.removeAll()
        if let totalBytes { try? await cache.setTotalBytes(track, totalBytes) }
        await cache.close(track)
    }

    func observe(_ handler: @escaping @Sendable (MediaTrackPipelineState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return id
    }

    var state: MediaTrackPipelineState {
        var timeline: MediaSegmentTimeline?
        if case .indexed(let layout) = layout { timeline = layout.timeline }
        return MediaTrackPipelineState(
            role: role, totalBytes: totalBytes, timeline: timeline, declaredDuration: declaredDuration,
            stages: [.download: MediaStageState(condition: condition, completed: completed, inFlight: inFlight)]
        )
    }

    var knownTotalBytes: Int64? { totalBytes }
    var isStopped: Bool { stopped }

    /// Waits until the track's first bytes have been read.
    func trackLayout() async throws -> TrackLayout {
        if let layout { return layout }
        if stopped { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let layout { continuation.resume(returning: layout) }
                else { layoutWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelLayoutWaiter(id) }
        }
    }

    /// Waits until every byte of `range` is cached, moving the download to it
    /// first. Waits through network failures; throws only when cancelled or
    /// stopped.
    func waitUntilAvailable(_ range: Range<Int64>) async throws {
        if completed.contains(range) { return }
        if stopped { throw CancellationError() }
        let gaps = completed.gaps(in: range)
        if let first = gaps.first { priorityOffset = first.lowerBound }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if completed.contains(range) { continuation.resume() }
                else { waiters[id] = (range, continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func read(_ range: Range<Int64>) async throws -> Data? {
        try await cache.read(track, range: range)
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func cancelLayoutWaiter(_ id: UUID) {
        layoutWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: driver

    private func run() async {
        completed = await cache.completed(track)
        totalBytes = await cache.totalBytes(track)
        // Bytes already cached satisfy waiters that arrived before this point;
        // nothing else would resume them when no new bytes are stored.
        resumeSatisfiedWaiters()
        publish()
        do {
            try await readLayout()
            condition = .running
            publish()
            try await downloadRemaining()
            condition = .complete
            publish()
            Logger.mediaCache.info("track_complete role=\(self.role.rawValue, privacy: .public) bytes=\(self.totalBytes ?? -1)")
            OSSignposter.mediaCache.emitEvent("VODTrackComplete", "role=\(self.role.rawValue, privacy: .public)")
        } catch is CancellationError {
            return
        } catch TrackDownloadError.stopped {
            // A background download the cache had no room for.
            Logger.mediaCache.notice("background_download_stopped role=\(self.role.rawValue, privacy: .public) reason=space")
        } catch {
            condition = .failed(error.localizedDescription)
            publish()
            Logger.mediaCache.error("track_failed role=\(self.role.rawValue, privacy: .public) message=\(error.localizedDescription)")
            for (_, waiter) in layoutWaiters { waiter.resume(throwing: error) }
            layoutWaiters.removeAll()
            for (_, waiter) in waiters { waiter.continuation.resume(throwing: error) }
            waiters.removeAll()
        }
        isFinished = true
        if let finishHandler { await finishHandler() }
    }

    private func readLayout() async throws {
        let signposter = OSSignposter.mediaCache
        let signpost = signposter.beginInterval("VODLayout", id: signposter.makeSignpostID(), "role=\(self.role.rawValue, privacy: .public)")
        var end = indexHint.map { $0.upperBound + 1 } ?? configuration.headerProbeBytes
        var resolved: TrackLayout?
        while resolved == nil {
            if let totalBytes { end = min(end, totalBytes) }
            try await ensure(0..<end)
            let available = min(end, totalBytes ?? end)
            let header = try await cache.read(track, range: 0..<available) ?? Data()
            switch FragmentedMP4.probe(header, indexHint: indexHint) {
            case .layout(let found):
                resolved = .indexed(found)
                let total = found.timeline.totalBytes
                if totalBytes == nil || totalBytes == total {
                    setTotal(total)
                } else if !didResetForMismatch {
                    // The cached bytes describe a different file than the one
                    // upstream now (or another rendition under the same key):
                    // start this track over rather than mix them.
                    Logger.mediaCache.notice("index_size_mismatch role=\(self.role.rawValue, privacy: .public) index=\(total) known=\(self.totalBytes ?? -1) reset=true")
                    didResetForMismatch = true
                    try await cache.reset(track)
                    completed = MediaRangeSet()
                    totalBytes = nil
                    end = indexHint.map { $0.upperBound + 1 } ?? configuration.headerProbeBytes
                    resolved = nil
                    continue
                } else {
                    // Fresh bytes still disagree with the server's length:
                    // trust the index, which is what the player reads.
                    Logger.mediaCache.notice("index_size_mismatch role=\(self.role.rawValue, privacy: .public) index=\(total) server=\(self.totalBytes ?? -1) reset=false")
                    totalBytes = nil
                    setTotal(total)
                }
            case .needBytes(let upTo):
                if let totalBytes, upTo > totalBytes || end >= totalBytes { resolved = .progressive }
                else if upTo <= end { resolved = .progressive }
                else { end = upTo }
            case .notIndexed:
                resolved = .progressive
            }
        }
        let result = resolved ?? .progressive
        layout = result
        let kind = if case .indexed = result { "indexed" } else { "progressive" }
        signposter.endInterval("VODLayout", signpost, "layout=\(kind, privacy: .public)")
        for (_, waiter) in layoutWaiters { waiter.resume(returning: result) }
        layoutWaiters.removeAll()
        publish()
    }

    /// Downloads `range` (with parallel pieces) before returning.
    private func ensure(_ range: Range<Int64>) async throws {
        while true {
            try Task.checkCancellation()
            // The file may turn out shorter than the range asked for.
            let bounded = range.lowerBound..<max(range.lowerBound, min(range.upperBound, totalBytes ?? range.upperBound))
            guard let gap = completed.gaps(in: bounded).first else { return }
            let piece = gap.lowerBound..<min(gap.upperBound, gap.lowerBound + configuration.pieceBytes)
            try await fetchWithRetry(piece)
        }
    }

    /// A background download stops when the cache is over its limit: the
    /// bytes would only push out other videos. Checked every 30 s.
    private func checkSpaceForBackground() async throws {
        guard priority == .background, lastSpaceCheck.duration(to: .now) > .seconds(30) else { return }
        lastSpaceCheck = .now
        if await cache.isOverLimit() { throw TrackDownloadError.stopped }
    }

    private func downloadRemaining() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                try Task.checkCancellation()
                try await checkSpaceForBackground()
                let limit = totalBytes == nil ? 1 : configuration.concurrentPieces
                while running < limit, let piece = nextPiece() {
                    inFlight.insert(piece)
                    running += 1
                    group.addTask { try await self.fetchWithRetry(piece) }
                }
                publish()
                if running == 0 {
                    if let totalBytes, completed.contains(0..<totalBytes) { return }
                    if totalBytes == nil, nextPiece() == nil { return }
                    // Nothing to plan but not complete: wait for a waiter or total to change.
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                _ = try await group.next()
                running -= 1
            }
        }
    }

    /// The next missing range, starting at the playhead's priority offset.
    private func nextPiece() -> Range<Int64>? {
        let busy = completed.union(inFlight)
        let urgent = waiters.values.contains { !completed.contains($0.range) }
        let size = urgent ? configuration.urgentPieceBytes : configuration.pieceBytes
        guard let totalBytes else {
            // Unknown length: continue sequentially after what we have.
            let start = busy.ranges.first.map { $0.lowerBound == 0 ? $0.upperBound : 0 } ?? 0
            return inFlight.isEmpty ? start..<(start + size) : nil
        }
        let gaps = busy.gaps(in: priorityOffset..<totalBytes) + busy.gaps(in: 0..<min(priorityOffset, totalBytes))
        guard let gap = gaps.first else { return nil }
        return gap.lowerBound..<min(gap.upperBound, gap.lowerBound + size)
    }

    // MARK: fetching

    private func fetchWithRetry(_ piece: Range<Int64>) async throws {
        defer {
            inFlight = MediaRangeSet(inFlight.ranges.flatMap { range -> [Range<Int64>] in
                MediaRangeSet([piece]).gaps(in: range)
            })
        }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try await fetchOnce(piece)
                consecutiveRefusals = 0
                if case .waitingForNetwork = condition { condition = .running }
                if case .refreshingSource = condition { condition = .running }
                publish()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as PieceFailure {
                attempt += 1
                let outcome: DownloadRetryPolicy.Outcome
                switch failure {
                case .status(let status): outcome = DownloadRetryPolicy.classify(status: status)
                case .network, .invalid, .storage: outcome = .retry
                case .signing: outcome = .refresh
                }
                if outcome == .refresh {
                    consecutiveRefusals += 1
                    if consecutiveRefusals >= configuration.retry.refusalsBeforeRefresh, refreshSigner != nil {
                        condition = .refreshingSource
                        publish()
                        do {
                            try await refreshedSigner()
                            consecutiveRefusals = 0
                            continue
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            Logger.mediaCache.error("refresh_failed role=\(self.role.rawValue, privacy: .public) message=\(error.localizedDescription)")
                        }
                    }
                }
                let delay = configuration.retry.delay(afterAttempt: attempt)
                condition = .waitingForNetwork(retryAt: Date().addingTimeInterval(delay), attempt: attempt,
                                               reason: failure.description)
                publish()
                Logger.mediaCache.notice("piece_retry role=\(self.role.rawValue, privacy: .public) attempt=\(attempt) delay=\(delay) reason=\(failure.description, privacy: .public)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One refresh at a time for every piece that hit an expired URL.
    private func refreshedSigner() async throws {
        if let refreshTask {
            signer = try await refreshTask.value
            return
        }
        guard let refreshSigner else { return }
        let task = Task { try await refreshSigner() }
        refreshTask = task
        defer { refreshTask = nil }
        signer = try await task.value
        Logger.mediaCache.notice("source_refreshed role=\(self.role.rawValue, privacy: .public)")
    }

    private enum PieceFailure: Error, CustomStringConvertible {
        case network(String)
        case status(Int)
        case invalid(String)
        /// The plugin could not produce the request (its handles may be gone after a reload).
        case signing(String)
        /// The cache could not store the bytes even after evicting.
        case storage(String)

        var description: String {
            switch self {
            case .network(let code): "network \(code)"
            case .status(let status): "http \(status)"
            case .invalid(let detail): "invalid \(detail)"
            case .signing(let detail): "signing \(detail)"
            case .storage(let detail): "storage \(detail)"
            }
        }
    }

    private func fetchOnce(_ piece: Range<Int64>) async throws {
        let signposter = OSSignposter.mediaCache
        let signpost = signposter.beginInterval("VODPiece", id: signposter.makeSignpostID(),
                                                "role=\(self.role.rawValue, privacy: .public) offset=\(piece.lowerBound) bytes=\(piece.count)")
        let started = ContinuousClock.now
        var outcome = "failed"
        defer { signposter.endInterval("VODPiece", signpost, "\(outcome, privacy: .public)") }
        let request: URLRequest
        do {
            request = try await signer.sign(piece)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome = "signing"
            throw PieceFailure.signing(String(describing: type(of: error)))
        }
        let data: Data
        let response: URLResponse
        do {
            let admitted = priority
            await scheduler?.admit(admitted)
            do {
                (data, response) = try await transport.data(for: request)
                await scheduler?.finish(admitted)
            } catch {
                await scheduler?.finish(admitted)
                throw error
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            outcome = "network"
            throw PieceFailure.network("\(error.code.rawValue)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcome = "network"
            throw PieceFailure.network(String(describing: type(of: error)))
        }
        guard let http = response as? HTTPURLResponse else { throw PieceFailure.invalid("no http response") }
        outcome = "status=\(http.statusCode)"
        if http.statusCode == 416, totalBytes == nil, piece.lowerBound > 0 {
            // Past the end of a file whose length the server never stated.
            setTotal(piece.lowerBound)
            return
        }
        guard (200..<300).contains(http.statusCode) else { throw PieceFailure.status(http.statusCode) }
        let accepted = try accept(data, for: piece, response: http)
        try await store(accepted.data, at: accepted.offset)
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? Double(data.count) / seconds : 0
        outcome = "ok bytes=\(data.count) kbps=\(Int(rate * 8 / 1_000))"
        if data.count >= 256 * 1_024, rate < 128 * 1_024 {
            Logger.mediaCache.notice("slow_piece role=\(self.role.rawValue, privacy: .public) host=\(request.url?.host ?? "", privacy: .private) bytes=\(data.count) seconds=\(seconds)")
        }
    }

    /// Validates a response and decides where its bytes belong.
    private func accept(_ data: Data, for piece: Range<Int64>, response: HTTPURLResponse) throws -> (data: Data, offset: Int64) {
        if response.statusCode == 206 {
            let contentRange = response.value(forHTTPHeaderField: "Content-Range")
            if let parsed = contentRange.flatMap(Self.parseContentRange) {
                guard parsed.start == piece.lowerBound else { throw PieceFailure.invalid("range start \(parsed.start)") }
                if let total = parsed.total { setTotal(total) }
            }
            guard data.count <= piece.count, !data.isEmpty else { throw PieceFailure.invalid("206 length \(data.count)") }
            if data.count < piece.count, totalBytes == nil { setTotal(piece.lowerBound + Int64(data.count)) }
            return (data, piece.lowerBound)
        }
        // 200: either exactly the range (range carried in the URL), or the
        // whole file from a server that ignores ranges.
        if data.count == piece.count { return (data, piece.lowerBound) }
        if piece.lowerBound == 0, data.count > piece.count {
            setTotal(Int64(data.count))
            return (data, 0)
        }
        if data.count < piece.count, !data.isEmpty {
            if let totalBytes, piece.lowerBound + Int64(data.count) != totalBytes {
                throw PieceFailure.invalid("200 length \(data.count)")
            }
            setTotal(piece.lowerBound + Int64(data.count))
            return (data, piece.lowerBound)
        }
        throw PieceFailure.invalid("200 length \(data.count)")
    }

    private func store(_ data: Data, at offset: Int64) async throws {
        do {
            completed = try await cache.writeMakingRoom(data, at: offset, to: track)
        } catch {
            // Still no room (or another I/O failure): retry later like a network failure.
            throw PieceFailure.storage(String(describing: type(of: error)))
        }
        resumeSatisfiedWaiters()
        publish()
    }

    private func setTotal(_ total: Int64) {
        guard total > 0, totalBytes != total else { return }
        totalBytes = total
        let cache = cache, track = track
        Task { try? await cache.setTotalBytes(track, total) }
    }

    private func resumeSatisfiedWaiters() {
        for (id, waiter) in waiters where completed.contains(waiter.range) {
            waiters[id] = nil
            waiter.continuation.resume()
        }
        // Keep downloading near the earliest range the player still waits for.
        if let pending = waiters.values.map(\.range.lowerBound).min() {
            priorityOffset = completed.gaps(in: pending..<(totalBytes ?? .max)).first?.lowerBound ?? priorityOffset
        }
    }

    private func publish() {
        let snapshot = state
        for observer in observers.values { observer(snapshot) }
    }

    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        // "bytes 0-1023/4096" or "bytes 0-1023/*"
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard let span = parts.first else { return nil }
        let bounds = span.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        let total = parts.count == 2 ? Int64(parts[1]) : nil
        return (start, end, total)
    }
}

extension MediaRangeSet {
    func union(_ other: MediaRangeSet) -> MediaRangeSet {
        var result = self
        result.formUnion(other)
        return result
    }
}
