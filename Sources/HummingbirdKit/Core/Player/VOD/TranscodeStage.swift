import Foundation
import os

/// The encoder the transcode stage uses; the app installs the platform's
/// (SwiftOpenUI `MediaTranscoder`), tests a fake.
struct TranscodeEncoder: Sendable {
    var isAvailable: @Sendable () -> Bool
    /// Whether background work is welcome right now (power, heat, charging).
    var conditionsAllow: @Sendable () async -> Bool
    /// Re-encodes the complete file at the first URL into the second.
    var transcode: @Sendable (URL, URL) async throws -> Void

    static let unavailable = TranscodeEncoder(isAvailable: { false }, conditionsAllow: { false },
                                              transcode: { _, _ in throw CancellationError() })
}

/// Optional transcoding (Quality setting, off by default) to save space: a
/// pipeline stage after download.
///
/// The downloaded originals are this stage's input buffer. A complete video
/// track is re-encoded into a new cache entry; only when that entry is stored
/// is the original deleted ("the originals are deleted as the buffer is
/// depleted by the next pipeline stage"), so a failure, crash or network drop
/// loses nothing: the original stays until it has been consumed. Output that
/// is not meaningfully smaller is discarded and the original kept. Work runs
/// one track at a time, off the main actor, only while the encoder says
/// conditions allow (not in Low Power Mode, not hot, charging on iOS), and
/// never on a track that is open (playing or downloading).
///
/// Not yet: transcoding segments while they are still being downloaded or
/// played; today the stage consumes finished downloads in the background.
actor TranscodeStage {
    static func transcodedIdentity(_ identity: String) -> String { identity + "|hevc" }

    private let cache: MediaCache
    private let scratch: URL
    private var encoder: TranscodeEncoder
    private(set) var isEnabled = false
    private var loop: Task<Void, Never>?
    /// Tracks whose re-encoding did not save space (kept as they are).
    private var notWorthIt = Set<String>()

    /// Transcoding is work that can wait: it pauses while energy is saved.
    private let policy: BackgroundWorkPolicy?

    init(cache: MediaCache, scratch: URL, encoder: TranscodeEncoder = .unavailable, policy: BackgroundWorkPolicy? = nil) {
        self.policy = policy
        self.cache = cache
        self.scratch = scratch
        self.encoder = encoder
    }

    func useEncoder(_ encoder: TranscodeEncoder) { self.encoder = encoder }

    var isAvailable: Bool { encoder.isAvailable() }

    /// `background`: also work through eligible tracks on its own (the app);
    /// tests call `runOnce` themselves.
    func setEnabled(_ enabled: Bool, background: Bool = true) {
        isEnabled = enabled
        if enabled, background, loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let worked = await self.runOnce()
                    try? await Task.sleep(for: .seconds(worked ? 1 : 60))
                }
            }
        } else if !enabled {
            loop?.cancel()
            loop = nil
        }
    }

    /// Transcodes one eligible track if there is one and conditions allow.
    /// Returns whether it did work.
    @discardableResult
    func runOnce() async -> Bool {
        guard isEnabled, policy?.defersNonUrgentWork != true, encoder.isAvailable(), await encoder.conditionsAllow() else { return false }
        let candidates = await cache.completeClosedTracks()
            .filter { Self.isVideoOriginal($0.identity) && !notWorthIt.contains($0.identity) }
        for candidate in candidates {
            let output = Self.transcodedIdentity(candidate.identity)
            if await cache.isComplete(identity: output) {
                // Already re-encoded: the original is a consumed buffer.
                await cache.remove(identity: candidate.identity)
                continue
            }
            guard let source = await cache.fileOfCompleteTrack(identity: candidate.identity) else { continue }
            let signposter = OSSignposter.mediaCache
            let signpost = signposter.beginInterval("Transcode", id: signposter.makeSignpostID())
            defer { signposter.endInterval("Transcode", signpost) }
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let destination = scratch.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try await encoder.transcode(source, destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0, Double(size) < Double(candidate.bytes) * 0.9 else {
                    try? FileManager.default.removeItem(at: destination)
                    notWorthIt.insert(candidate.identity)
                    Logger.mediaCache.info("transcode_kept_original bytes=\(candidate.bytes) output=\(size)")
                    return true
                }
                try await cache.importFile(destination, identity: output)
                // Stored: now the original is consumed.
                await cache.remove(identity: candidate.identity)
                Logger.mediaCache.info("transcode_done bytes=\(candidate.bytes) output=\(size)")
                return true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                notWorthIt.insert(candidate.identity)
                Logger.mediaCache.error("transcode_failed message=\(error.localizedDescription)")
                return true
            }
        }
        return false
    }

    /// Video (or muxed) file tracks of the VOD cache, not already transcoded.
    static func isVideoOriginal(_ identity: String) -> Bool {
        identity.hasPrefix("vod-v2|") && !identity.hasSuffix("|hevc")
            && (identity.contains("|video|") || identity.contains("|muxed|"))
    }
}
