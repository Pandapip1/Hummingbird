import Foundation
import SwiftOpenUI

/// A chapter as Grayjay plugins report it (`getContentChapters`).
struct PlaybackChapter: Sendable, Decodable, Hashable {
    var name: String
    var timeStart: Double
    var timeEnd: Double
    /// Grayjay's ChapterType: 0 normal; 5 skippable, 6 skip, 7 skip once
    /// (SponsorBlock-style segments).
    var type: Int

    enum CodingKeys: String, CodingKey { case name, timeStart, timeEnd, type }

    init(name: String, timeStart: Double, timeEnd: Double, type: Int) {
        self.name = name; self.timeStart = timeStart; self.timeEnd = timeEnd; self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.looseString(.name) ?? ""
        timeStart = Double(c.looseString(.timeStart) ?? "") ?? 0
        timeEnd = Double(c.looseString(.timeEnd) ?? "") ?? 0
        type = c.looseInt(.type) ?? 0
    }

    var isFlagged: Bool { type != 0 }
}

/// What the seek bar shows for the current video: its chapters (normal ones
/// split the capsule, skippable ones are flagged regions), each track's
/// pipeline lane per stage, discontinuities, and for live streams the
/// recorded window.
enum PlaybackScrubber {
    static func content(pipeline: MediaPipelineSnapshot, duration: Double, chapters: [PlaybackChapter],
                        isLive: Bool) -> ScrubberContent {
        let lanes = pipeline.tracks.map { track in
            ScrubberLane(label: track.role == .audio ? "Audio" : "Video", segments: laneSegments(track))
        }
        let recorded = pipeline.mediaDuration
        let live: ScrubberLive? = isLive
            ? ScrubberLive(edge: recorded ?? duration, hasEnded: !pipeline.tracks.isEmpty && pipeline.isComplete)
            : nil
        return ScrubberContent(
            duration: duration,
            chapters: chapters.filter { !$0.isFlagged }.map { ScrubberChapter(start: $0.timeStart, end: $0.timeEnd, title: $0.name) },
            lanes: lanes,
            flags: chapters.filter(\.isFlagged).map {
                ScrubberFlag(start: $0.timeStart, end: $0.timeEnd, category: $0.name, title: $0.name.isEmpty ? "Skippable segment" : $0.name)
            },
            discontinuities: Array(Set(pipeline.tracks.flatMap(\.discontinuities))).sorted(),
            live: live
        )
    }

    /// A track's lane: what is downloaded, and what is being fetched now.
    /// Later stages (transcoding) add their own colours as they report.
    static func laneSegments(_ track: MediaTrackPipelineState) -> [ScrubberLane.Segment] {
        var segments = track.timeRanges(for: .download).map {
            ScrubberLane.Segment(range: ScrubberRange(start: $0.lowerBound, end: $0.upperBound), stage: .downloaded)
        }
        let inFlight = track.stage(.download).inFlight
        if !inFlight.isEmpty {
            var probe = track
            probe.stages[.download] = MediaStageState(condition: .running, completed: inFlight, inFlight: MediaRangeSet())
            segments += probe.timeRanges(for: .download).map {
                ScrubberLane.Segment(range: ScrubberRange(start: $0.lowerBound, end: $0.upperBound), stage: .inFlight)
            }
        }
        if let transcoded = track.stages[.transcode] {
            var probe = track
            probe.stages[.download] = transcoded
            segments += probe.timeRanges(for: .download).map {
                ScrubberLane.Segment(range: ScrubberRange(start: $0.lowerBound, end: $0.upperBound), stage: .processed)
            }
        }
        return segments
    }
}
