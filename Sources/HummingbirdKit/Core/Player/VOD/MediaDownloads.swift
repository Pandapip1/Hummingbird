import Foundation
import os

/// How urgently a download wants the network.
enum DownloadPriority: Int, Sendable, Comparable {
    /// Nobody is watching: finish when the network is otherwise idle.
    case background = 0
    /// Something on screen plays it.
    case foreground = 1

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Shares the network between downloads. Foreground requests (what is
/// playing) always go at once; background requests wait while any
/// foreground request is running and run at most `backgroundLimit` at a
/// time, so leftover downloads use only bandwidth that playback leaves idle.
actor DownloadScheduler {
    private let backgroundLimit: Int
    private var foregroundRunning = 0
    private var backgroundRunning = 0
    private var backgroundWaiters: [(ticket: UUID, continuation: CheckedContinuation<DownloadPriority, Never>)] = []
    /// Promotions that arrived before their request reached the queue.
    private var promotedEarly = Set<UUID>()

    init(backgroundLimit: Int = 2) {
        self.backgroundLimit = backgroundLimit
    }

    /// Waits for a slot and returns the priority it was admitted at: a queued
    /// background request can be promoted (`promote`) when the player starts
    /// waiting on its track. Every `admit` is balanced by `finish` with the
    /// returned priority.
    @discardableResult
    func admit(_ priority: DownloadPriority, ticket: UUID = UUID()) async -> DownloadPriority {
        if priority == .foreground || promotedEarly.remove(ticket) != nil {
            foregroundRunning += 1
            return .foreground
        }
        if foregroundRunning == 0, backgroundRunning < backgroundLimit {
            backgroundRunning += 1
            return .background
        }
        // `wakeBackground` or `promote` counts this request before resuming it.
        return await withCheckedContinuation { backgroundWaiters.append((ticket, $0)) }
    }

    /// Lets queued background requests run now, as foreground.
    func promote(_ tickets: Set<UUID>) {
        var remaining = tickets
        backgroundWaiters.removeAll { waiter in
            guard remaining.remove(waiter.ticket) != nil else { return false }
            foregroundRunning += 1
            waiter.continuation.resume(returning: .foreground)
            return true
        }
        promotedEarly.formUnion(remaining)
    }

    func finish(_ priority: DownloadPriority) {
        switch priority {
        case .foreground: foregroundRunning = max(0, foregroundRunning - 1)
        case .background: backgroundRunning = max(0, backgroundRunning - 1)
        }
        wakeBackground()
    }

    private func wakeBackground() {
        while foregroundRunning == 0, backgroundRunning < backgroundLimit, !backgroundWaiters.isEmpty {
            backgroundRunning += 1
            backgroundWaiters.removeFirst().continuation.resume(returning: .background)
        }
    }

    var snapshot: (foreground: Int, background: Int, waiting: Int) {
        (foregroundRunning, backgroundRunning, backgroundWaiters.count)
    }
}

/// Every VOD download, owned by the media cache rather than by a player.
///
/// A player that opens a video holds its downloads in the foreground; when
/// the player closes, switches quality or goes away, the downloads continue
/// in the background until the track is complete, so the whole video ends up
/// cached as the design asks. A background download stops early only when the
/// cache could not keep it (it is over its limit). Opening a video whose
/// download is already running reuses that download.
actor MediaDownloads {
    let cache: MediaCache
    let scheduler: DownloadScheduler
    private var transport: any MediaTransport
    private var tracks: [String: Entry<TrackDownloader>] = [:]
    private var renditions: [String: Entry<HLSRenditionDownloader>] = [:]
    private var recordings: [String: Entry<LiveHLSRecorder>] = [:]

    private struct Entry<Downloader> {
        let downloader: Downloader
        var holders: Int
    }

    init(cache: MediaCache, scheduler: DownloadScheduler = DownloadScheduler(),
         transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession)) {
        self.cache = cache
        self.scheduler = scheduler
        self.transport = transport
    }

    /// How downloads reach the network; the app installs one that keeps
    /// going while it is suspended (`BackgroundTransport`). Applies to
    /// downloads started afterwards.
    func useTransport(_ transport: any MediaTransport) {
        self.transport = transport
    }

    var currentTransport: any MediaTransport { transport }

    /// The running download for `spec`'s track, or a new one; held in the
    /// foreground until `release`.
    func hold(_ spec: VODTrackSpec) async throws -> TrackDownloader {
        if var entry = tracks[spec.identity], !(await entry.downloader.isStopped) {
            entry.holders += 1
            tracks[spec.identity] = entry
            await entry.downloader.setPriority(.foreground)
            return entry.downloader
        }
        let track = try await cache.open(identity: spec.identity)
        let downloader = TrackDownloader(role: spec.role, cache: cache, track: track, signer: spec.signer,
                                         indexHint: spec.indexHint, declaredDuration: spec.declaredDuration,
                                         refreshSigner: spec.refresh, transport: transport, scheduler: scheduler,
                                         reportsTranscoded: spec.isTranscoded)
        tracks[spec.identity] = Entry(downloader: downloader, holders: 1)
        let identity = spec.identity
        await downloader.onFinish { [weak self] in await self?.finished(track: identity) }
        await downloader.start()
        return downloader
    }

    /// The running download for an HLS rendition, or a new one.
    func hold(rendition identity: String, make: @Sendable () -> HLSRenditionDownloader) async -> HLSRenditionDownloader {
        if var entry = renditions[identity], !(await entry.downloader.isStopped) {
            entry.holders += 1
            renditions[identity] = entry
            await entry.downloader.setPriority(.foreground)
            return entry.downloader
        }
        let downloader = make()
        renditions[identity] = Entry(downloader: downloader, holders: 1)
        await downloader.onFinish { [weak self] in await self?.finished(rendition: identity) }
        await downloader.start()
        return downloader
    }

    /// The holder no longer plays the track: once nobody does, it continues
    /// in the background.
    func release(track identity: String) async {
        guard var entry = tracks[identity] else { return }
        entry.holders -= 1
        tracks[identity] = entry
        guard entry.holders <= 0 else { return }
        if await entry.downloader.isFinished {
            await entry.downloader.stop()
            tracks[identity] = nil
        } else {
            await entry.downloader.setPriority(.background)
        }
    }

    func release(rendition identity: String) async {
        guard var entry = renditions[identity] else { return }
        entry.holders -= 1
        renditions[identity] = entry
        guard entry.holders <= 0 else { return }
        if await entry.downloader.isFinished {
            await entry.downloader.stop()
            renditions[identity] = nil
        } else {
            await entry.downloader.setPriority(.background)
        }
    }

    /// The running recording of a live rendition, or a new one.
    func hold(recording identity: String, make: @Sendable () -> LiveHLSRecorder) async -> LiveHLSRecorder {
        if var entry = recordings[identity], !(await entry.downloader.isStopped) {
            entry.holders += 1
            recordings[identity] = entry
            await entry.downloader.setPriority(.foreground)
            return entry.downloader
        }
        let recorder = make()
        recordings[identity] = Entry(downloader: recorder, holders: 1)
        await recorder.onFinish { [weak self] in await self?.finished(recording: identity) }
        await recorder.start()
        return recorder
    }

    func release(recording identity: String) async {
        guard var entry = recordings[identity] else { return }
        entry.holders -= 1
        recordings[identity] = entry
        guard entry.holders <= 0 else { return }
        if await entry.downloader.isFinished {
            await entry.downloader.stop()
            recordings[identity] = nil
        } else {
            await entry.downloader.setPriority(.background)
        }
    }

    private func finished(recording identity: String) async {
        guard let entry = recordings[identity], entry.holders <= 0 else { return }
        await entry.downloader.stop()
        recordings[identity] = nil
    }

    // MARK: the downloads list

    /// One video's downloads as the downloads list shows them.
    private struct Group {
        var info: DownloadInfo
        var tracks: [String] = []
        var renditions: [String] = []
        var recordings: [String] = []
        var paused = false
        var stopped = false
        var finishedAt: Date?
        var lastBytes: Int64 = 0
        var lastSample = ContinuousClock.now
        var bytesPerSecond: Double = 0
    }

    private var groups: [String: Group] = [:]
    private var groupOrder: [String] = []

    /// Names the downloads a session holds, for the downloads list.
    func describe(_ info: DownloadInfo, tracks: [String] = [], renditions: [String] = [], recordings: [String] = []) {
        var group = groups[info.id] ?? Group(info: info)
        group.info = info
        group.tracks = Array(Set(group.tracks + tracks))
        group.renditions = Array(Set(group.renditions + renditions))
        group.recordings = Array(Set(group.recordings + recordings))
        group.stopped = false
        group.finishedAt = nil
        groups[info.id] = group
        groupOrder.removeAll { $0 == info.id }
        groupOrder.insert(info.id, at: 0)
    }

    /// The downloads list, newest first.
    func snapshot() async -> [DownloadSnapshot] {
        var out: [DownloadSnapshot] = []
        for id in groupOrder {
            guard var group = groups[id] else { continue }
            var states: [MediaTrackPipelineState] = []
            var playing = false
            for identity in group.tracks {
                guard let entry = tracks[identity] else { continue }
                states.append(await entry.downloader.state)
                playing = playing || entry.holders > 0
            }
            for identity in group.renditions {
                guard let entry = renditions[identity] else { continue }
                states.append(await entry.downloader.state)
                playing = playing || entry.holders > 0
            }
            for identity in group.recordings {
                guard let entry = recordings[identity] else { continue }
                states.append(await entry.downloader.state)
                playing = playing || entry.holders > 0
            }
            let fractions = states.map { state -> Double in
                guard let total = state.totalBytes, total > 0 else { return 0 }
                return Double(state.stage(.download).completed.byteCount) / Double(total)
            }
            let fraction = fractions.isEmpty ? (group.finishedAt == nil ? 0 : 1) : fractions.reduce(0, +) / Double(fractions.count)
            // Bytes only for file tracks; HLS progress counts segments.
            let bytes = states.filter { $0.timeline?.initialization != 0..<0 }
                .reduce(Int64(0)) { $0 + $1.stage(.download).completed.byteCount }
            let elapsed = group.lastSample.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds >= 1 {
                group.bytesPerSecond = max(0, Double(bytes - group.lastBytes) / seconds)
                group.lastBytes = bytes
                group.lastSample = .now
            }
            let running = !states.isEmpty
            let complete = !states.isEmpty && states.allSatisfy { if case .complete = $0.stage(.download).condition { true } else { false } }
            if complete, group.finishedAt == nil { group.finishedAt = Date() }
            let waiting = states.contains { if case .waitingForNetwork = $0.stage(.download).condition { true } else { false } }
            let state: DownloadSnapshot.State =
                group.stopped ? .stopped
                : complete || (!running && group.finishedAt != nil) ? .complete
                : group.paused ? .paused
                : waiting ? .waitingForNetwork
                : running ? .downloading
                : .stopped
            groups[id] = group
            out.append(DownloadSnapshot(id: id, info: group.info, fraction: fraction, bytes: bytes,
                                        bytesPerSecond: state == .downloading ? group.bytesPerSecond : 0,
                                        state: state, isPlaying: playing, finishedAt: group.finishedAt))
        }
        return out
    }

    /// Pauses or resumes a video's downloads. Returns once they have.
    func setPaused(_ paused: Bool, download id: String) async {
        guard var group = groups[id] else { return }
        group.paused = paused
        groups[id] = group
        for identity in group.tracks { await tracks[identity]?.downloader.setPaused(paused) }
        for identity in group.renditions { await renditions[identity]?.downloader.setPaused(paused) }
        for identity in group.recordings { await recordings[identity]?.downloader.setPaused(paused) }
    }

    /// Stops a video's downloads; what was downloaded stays cached. A video
    /// that is playing keeps downloading (it is needed).
    func stop(download id: String) async {
        guard var group = groups[id] else { return }
        for identity in group.tracks where (tracks[identity]?.holders ?? 0) <= 0 {
            await tracks.removeValue(forKey: identity)?.downloader.stop()
        }
        for identity in group.renditions where (renditions[identity]?.holders ?? 0) <= 0 {
            await renditions.removeValue(forKey: identity)?.downloader.stop()
        }
        for identity in group.recordings where (recordings[identity]?.holders ?? 0) <= 0 {
            await recordings.removeValue(forKey: identity)?.downloader.stop()
        }
        group.stopped = true
        groups[id] = group
    }

    /// Stops a video's downloads and deletes what they cached. Not while the
    /// video is playing.
    func remove(download id: String) async -> Bool {
        guard let group = groups[id] else { return true }
        let held = group.tracks.contains { (tracks[$0]?.holders ?? 0) > 0 }
            || group.renditions.contains { (renditions[$0]?.holders ?? 0) > 0 }
            || group.recordings.contains { (recordings[$0]?.holders ?? 0) > 0 }
        guard !held else { return false }
        var identities = group.tracks
        for identity in group.renditions {
            if let downloader = renditions[identity]?.downloader { identities += await downloader.cacheIdentities }
        }
        for identity in group.recordings {
            if let recorder = recordings[identity]?.downloader { identities += await recorder.cacheIdentities }
        }
        await stop(download: id)
        for identity in identities { await cache.remove(identity: identity) }
        groups[id] = nil
        groupOrder.removeAll { $0 == id }
        return true
    }

    /// Forgets finished and stopped entries (their cached data stays).
    func clearFinished() async {
        let states = Dictionary(uniqueKeysWithValues: (await snapshot()).map { ($0.id, $0.state) })
        for id in groupOrder where states[id] == .complete || states[id] == .stopped {
            groups[id] = nil
        }
        groupOrder.removeAll { groups[$0] == nil }
    }

    /// Stops every download (tests, sign-out).
    func stopAll() async {
        for entry in tracks.values { await entry.downloader.stop() }
        for entry in renditions.values { await entry.downloader.stop() }
        for entry in recordings.values { await entry.downloader.stop() }
        recordings.removeAll()
        tracks.removeAll()
        renditions.removeAll()
    }

    private func finished(track identity: String) async {
        guard let entry = tracks[identity] else { return }
        if entry.holders <= 0 {
            await entry.downloader.stop()
            tracks[identity] = nil
        }
    }

    private func finished(rendition identity: String) async {
        guard let entry = renditions[identity] else { return }
        if entry.holders <= 0 {
            await entry.downloader.stop()
            renditions[identity] = nil
        }
    }
}

/// What the downloads list shows for a video.
struct DownloadInfo: Sendable, Hashable {
    /// Stable identity of the video (plugin and content URL).
    var id: String
    var title: String
    var contentURL: String
    var thumbnail: URL?
    var isLive: Bool
}

/// One row of the downloads list.
struct DownloadSnapshot: Sendable, Identifiable, Equatable {
    enum State: Sendable, Equatable {
        case downloading, waitingForNetwork, paused, complete, stopped
    }
    var id: String
    var info: DownloadInfo
    /// 0…1 over every track of the video.
    var fraction: Double
    /// Bytes downloaded (file tracks; HLS progress is in `fraction`).
    var bytes: Int64
    var bytesPerSecond: Double
    var state: State
    /// Some window is playing it.
    var isPlaying: Bool
    var finishedAt: Date?
}
