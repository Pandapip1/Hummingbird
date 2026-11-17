import Foundation

// The observable state of the VOD media pipeline.
//
// Every video is downloaded in full into the media cache and played only from
// local data (`MediaCache`, `TrackDownloader`, `LocalMediaServer`). Each track (video, audio, or a
// muxed file) moves through pipeline stages. Today there is one stage,
// `download`; optional transcoding (task 35) will add stages that consume
// the previous stage's output as a buffer. A stage's progress is a set of
// byte ranges, which may be non-contiguous (the downloader fetches the
// playhead's neighbourhood first and fills the rest in parallel). With the
// track's segment timeline the same ranges map to media time, which is what a
// per-stage, per-track seek bar (task 65) draws.

/// A set of disjoint, sorted, half-open byte ranges.
struct MediaRangeSet: Sendable, Hashable, Codable {
    private(set) var ranges: [Range<Int64>] = []

    init() {}
    init<S: Sequence>(_ ranges: S) where S.Element == Range<Int64> {
        for range in ranges { insert(range) }
    }

    var isEmpty: Bool { ranges.isEmpty }
    var byteCount: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound
        var upper = range.upperBound
        var result: [Range<Int64>] = []
        result.reserveCapacity(ranges.count + 1)
        var inserted = false
        for existing in ranges {
            if existing.upperBound < lower {
                result.append(existing)
            } else if existing.lowerBound > upper {
                if !inserted { result.append(lower..<upper); inserted = true }
                result.append(existing)
            } else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        if !inserted { result.append(lower..<upper) }
        ranges = result
    }

    mutating func formUnion(_ other: MediaRangeSet) {
        for range in other.ranges { insert(range) }
    }

    func contains(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// The parts of `range` that are not in the set, in order.
    func gaps(in range: Range<Int64>) -> [Range<Int64>] {
        var gaps: [Range<Int64>] = []
        var cursor = range.lowerBound
        for existing in ranges where existing.upperBound > cursor && existing.lowerBound < range.upperBound {
            if existing.lowerBound > cursor { gaps.append(cursor..<existing.lowerBound) }
            cursor = max(cursor, existing.upperBound)
            if cursor >= range.upperBound { break }
        }
        if cursor < range.upperBound { gaps.append(cursor..<range.upperBound) }
        return gaps
    }

    /// How many bytes from `offset` onward are available without a gap.
    func contiguousBytes(from offset: Int64) -> Int64 {
        guard let range = ranges.first(where: { $0.contains(offset) }) else { return 0 }
        return range.upperBound - offset
    }
}

/// A pipeline stage. Later stages (transcoding, task 35) consume earlier
/// stages' output; each keeps its own progress.
enum MediaPipelineStage: String, Sendable, Hashable, CaseIterable, Codable {
    case download
    /// Optional transcoding to save space (Quality setting): consumes the
    /// downloaded originals as its buffer.
    case transcode
}

enum MediaTrackRole: String, Sendable, Hashable, Codable {
    case video, audio, muxed
}

/// What a stage is doing right now.
enum MediaStageCondition: Sendable, Equatable {
    case starting
    case running
    /// The network failed; the stage retries on its own at `retryAt`.
    /// Playback of data that is already local continues.
    case waitingForNetwork(retryAt: Date, attempt: Int, reason: String)
    /// The upstream URL expired or was refused; the stage is asking the
    /// plugin for fresh playback details.
    case refreshingSource
    /// Paused by the user (the downloads list).
    case paused
    case complete
    /// The stage gave up. Only unrecoverable problems (corrupt media the
    /// player cannot use) end here; network failures never do.
    case failed(String)
}

struct MediaStageState: Sendable, Equatable {
    var condition: MediaStageCondition = .starting
    /// Bytes this stage has produced.
    var completed = MediaRangeSet()
    /// Bytes being produced now.
    var inFlight = MediaRangeSet()
}

/// Maps byte offsets of a fragmented MP4 track to media time.
struct MediaSegmentTimeline: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var bytes: Range<Int64>
        var start: Double
        var duration: Double
    }
    var initialization: Range<Int64>
    var segments: [Segment]

    var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }
    var totalBytes: Int64 { segments.last?.bytes.upperBound ?? initialization.upperBound }

    /// Media time ranges whose bytes are fully inside `set`, merged.
    func timeRanges(covered set: MediaRangeSet) -> [ClosedRange<Double>] {
        guard set.contains(initialization) else { return [] }
        var result: [ClosedRange<Double>] = []
        for segment in segments where set.contains(segment.bytes) {
            let end = segment.start + segment.duration
            if let last = result.last, abs(last.upperBound - segment.start) < 0.001 {
                result[result.count - 1] = last.lowerBound...end
            } else {
                result.append(segment.start...end)
            }
        }
        return result
    }

    /// The segment containing time `seconds`, or the last one.
    func segmentIndex(at seconds: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        return segments.lastIndex(where: { $0.start <= seconds }) ?? 0
    }
}

/// One track's pipeline state.
struct MediaTrackPipelineState: Sendable, Equatable {
    var role: MediaTrackRole
    /// Total bytes, once known.
    var totalBytes: Int64?
    /// Present for fragmented MP4 tracks once their index has been read.
    var timeline: MediaSegmentTimeline?
    /// Declared duration, used to estimate time ranges for tracks without a timeline.
    var declaredDuration: Double?
    var stages: [MediaPipelineStage: MediaStageState] = [:]
    /// Media times of discontinuities (ad breaks, encoder restarts).
    var discontinuities: [Double] = []

    func stage(_ stage: MediaPipelineStage) -> MediaStageState { stages[stage] ?? MediaStageState() }

    var isComplete: Bool {
        guard let totalBytes else { return false }
        // Every stage this track runs (download always) has produced everything.
        let present = Set(stages.keys).union([.download])
        return present.allSatisfy { stage($0).completed.contains(0..<totalBytes) }
    }

    /// Media time ranges a stage has completed. Without a segment timeline
    /// the mapping is proportional to bytes, which is approximate.
    func timeRanges(for stage: MediaPipelineStage) -> [ClosedRange<Double>] {
        let completed = self.stage(stage).completed
        if let timeline { return timeline.timeRanges(covered: completed) }
        guard let totalBytes, totalBytes > 0, let declaredDuration, declaredDuration > 0 else { return [] }
        return completed.ranges.map { range in
            (Double(range.lowerBound) / Double(totalBytes) * declaredDuration)...(Double(range.upperBound) / Double(totalBytes) * declaredDuration)
        }
    }
}

/// The whole presentation's pipeline state, published to the player model.
struct MediaPipelineSnapshot: Sendable, Equatable {
    var tracks: [MediaTrackPipelineState] = []

    static let empty = MediaPipelineSnapshot()

    var isComplete: Bool { !tracks.isEmpty && tracks.allSatisfy(\.isComplete) }

    /// The presentation's length from the tracks' segment indexes: the sum of
    /// their segments, and the shorter track when video and audio differ (as
    /// the player ends there too). Nil unless every track is indexed.
    var mediaDuration: Double? {
        let durations = tracks.compactMap { $0.timeline?.duration }
        guard !tracks.isEmpty, durations.count == tracks.count else { return nil }
        return durations.min()
    }

    /// The most urgent condition across tracks, for a status line.
    var waitingForNetwork: Bool {
        tracks.contains { track in
            track.stages.values.contains { if case .waitingForNetwork = $0.condition { true } else { false } }
        }
    }

    /// Seconds of media playable from `time` on every track without a gap.
    func playableAhead(of time: Double, stage: MediaPipelineStage = .download) -> Double {
        guard !tracks.isEmpty else { return 0 }
        return tracks.map { track in
            guard let range = track.timeRanges(for: stage).first(where: { $0.contains(time) }) else { return 0 }
            return range.upperBound - time
        }.min() ?? 0
    }
}
