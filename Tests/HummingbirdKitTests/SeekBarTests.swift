import Foundation
import XCTest
import SwiftOpenUI
@testable import HummingbirdKit

/// The seek bar (task 65): chapters split the capsule, lanes and flags map
/// to positions, live streams show their recorded window relative to the
/// edge, the thumb does not move while the edge advances during a scrub, and
/// assistive technology reads position, chapter, downloaded ranges and flags.
final class SeekBarTests: XCTestCase {
    private let vod = ScrubberContent(
        duration: 100,
        chapters: [ScrubberChapter(start: 0, end: 40, title: "Intro"), ScrubberChapter(start: 40, end: 100, title: "Main")],
        lanes: [ScrubberLane(label: "Video", segments: [.init(range: .init(start: 0, end: 30), stage: .downloaded),
                                                        .init(range: .init(start: 60, end: 70), stage: .downloaded)])],
        flags: [ScrubberFlag(start: 50, end: 55, category: "sponsor", title: "Sponsor")]
    )

    func testChaptersSplitTheCapsuleWithGaps() {
        let layout = ScrubberLayout(content: vod, width: 200)
        let pieces = layout.capsuleSegments
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].upperBound, 80 - ScrubberLayout.chapterGap / 2, accuracy: 0.001)
        XCTAssertEqual(pieces[1].lowerBound, 80 + ScrubberLayout.chapterGap / 2, accuracy: 0.001)
        XCTAssertEqual(layout.chapter(at: 45)?.title, "Main")
        XCTAssertEqual(layout.preview(at: 10), "0:10 · Intro")
    }

    func testLanesAndFlagsMapToNonContiguousPositions() {
        let layout = ScrubberLayout(content: vod, width: 200)
        let lane = layout.laneRects(vod.lanes[0])
        XCTAssertEqual(lane.count, 2, "non-contiguous ranges stay separate")
        XCTAssertEqual(lane[1].range.lowerBound, 120, accuracy: 0.001)
        XCTAssertEqual(layout.flagRects.first?.range.lowerBound ?? 0, 100, accuracy: 0.001)
        XCTAssertGreaterThan(layout.laneY(0), 0, "lanes sit below the capsule's top")
        XCTAssertLessThan(ScrubberLayout.flagY, 0, "flags sit above it")
    }

    func testAccessibilityReadsPositionChapterRangesAndFlags() {
        let text = ScrubberLayout(content: vod, width: 200).accessibilityValue(52)
        XCTAssertTrue(text.contains("52 seconds of 1 minute 40 seconds"))
        XCTAssertTrue(text.contains("chapter Main"))
        XCTAssertTrue(text.contains("in Sponsor"))
        XCTAssertTrue(text.contains("Video downloaded 0 seconds to 30 seconds, 1 minute to 1 minute 10 seconds"))
    }

    func testLiveBarShowsTheRecordedWindowRelativeToTheEdge() {
        let live = ScrubberContent(duration: 0, live: ScrubberLive(edge: 600))
        let layout = ScrubberLayout(content: live, width: 300)
        XCTAssertTrue(layout.isAtLiveEdge(599))
        XCTAssertEqual(layout.trailingLabel(599), "LIVE")
        XCTAssertEqual(layout.trailingLabel(480), "−2:00 behind live")
        XCTAssertEqual(layout.x(for: 300), 150, accuracy: 0.001, "the whole recording is scrubbable")

        // The edge advances mid-scrub: with the end frozen the thumb stays put.
        let grown = ScrubberContent(duration: 0, live: ScrubberLive(edge: 660))
        let frozen = ScrubberLayout(content: grown, width: 300, frozenEnd: 600)
        XCTAssertEqual(frozen.x(for: 300), layout.x(for: 300), accuracy: 0.001)

        let ended = ScrubberContent(duration: 0, live: ScrubberLive(edge: 660, hasEnded: true))
        XCTAssertFalse(ended.isLive, "after the stream ends it is an ordinary bar")
        XCTAssertEqual(ScrubberLayout(content: ended, width: 300).trailingLabel(10), "11:00")
    }

    func testPipelineAndChaptersBecomeScrubberContent() throws {
        var completed = MediaRangeSet()
        completed.insert(0..<2)
        let timeline = MediaSegmentTimeline(initialization: 0..<0, segments: [
            .init(bytes: 0..<1, start: 0, duration: 4), .init(bytes: 1..<2, start: 4, duration: 4), .init(bytes: 2..<3, start: 8, duration: 4),
        ])
        var inFlight = MediaRangeSet()
        inFlight.insert(2..<3)
        let track = MediaTrackPipelineState(role: .video, totalBytes: 3, timeline: timeline, declaredDuration: 12,
                                            stages: [.download: MediaStageState(condition: .running, completed: completed, inFlight: inFlight)],
                                            discontinuities: [8])
        let chapters = [PlaybackChapter(name: "Intro", timeStart: 0, timeEnd: 6, type: 0),
                        PlaybackChapter(name: "Sponsor", timeStart: 6, timeEnd: 9, type: 5)]
        let content = PlaybackScrubber.content(pipeline: MediaPipelineSnapshot(tracks: [track]), duration: 12,
                                               chapters: chapters, isLive: false)
        XCTAssertEqual(content.chapters.map(\.title), ["Intro"])
        XCTAssertEqual(content.flags.map(\.title), ["Sponsor"], "skippable chapters are flagged regions")
        XCTAssertEqual(content.discontinuities, [8])
        let lane = try XCTUnwrap(content.lanes.first)
        XCTAssertEqual(lane.segments.first { $0.stage == .downloaded }?.range, ScrubberRange(start: 0, end: 8))
        XCTAssertEqual(lane.segments.first { $0.stage == .inFlight }?.range, ScrubberRange(start: 8, end: 12))

        let live = PlaybackScrubber.content(pipeline: MediaPipelineSnapshot(tracks: [track]), duration: 12,
                                            chapters: [], isLive: true)
        XCTAssertEqual(live.live?.edge ?? 0, 12, accuracy: 0.001)
        XCTAssertTrue(live.isLive)
    }
}
