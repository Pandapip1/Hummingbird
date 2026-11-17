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
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    init(backgroundLimit: Int = 2) {
        self.backgroundLimit = backgroundLimit
    }

    /// Waits for a slot. Every `admit` is balanced by `finish` with the same priority.
    func admit(_ priority: DownloadPriority) async {
        switch priority {
        case .foreground:
            foregroundRunning += 1
        case .background:
            if foregroundRunning == 0, backgroundRunning < backgroundLimit {
                backgroundRunning += 1
                return
            }
            await withCheckedContinuation { backgroundWaiters.append($0) }
            // `wakeBackground` counted this request before resuming it.
        }
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
            backgroundWaiters.removeFirst().resume()
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
    private let transport: any MediaTransport
    private var tracks: [String: Entry<TrackDownloader>] = [:]
    private var renditions: [String: Entry<HLSRenditionDownloader>] = [:]

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
                                         refreshSigner: spec.refresh, transport: transport, scheduler: scheduler)
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

    /// Stops every download (tests, sign-out).
    func stopAll() async {
        for entry in tracks.values { await entry.downloader.stop() }
        for entry in renditions.values { await entry.downloader.stop() }
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
