import Foundation
import os

/// Times one video's way from "load" to its first frame and logs one summary
/// line, so a slow start can be attributed to a stage:
///
///     startup_timing select_ms=… resolve_ms=… first_bytes_ms=… player_loaded_ms=… first_frame_ms=…
///
/// Stages, each measured from the start of `PlayerModel.load`:
/// - `selected`: a source was chosen (after details were decoded).
/// - `resolved`: the plugin produced what is needed to fetch the media
///   (request modifier / generated manifest), and for cached VOD the first
///   bytes of every track (their layout) are local.
/// - `firstBytes`: every track has its first downloaded bytes.
/// - `playerLoaded`: the platform player accepted the item.
/// - `firstFrame`: playback time first advanced.
///
/// The time before `load` (routing and `getContentDetails`) is logged by
/// `PlatformService.details` as `details_timing`; plugin calls are
/// signposted (`PluginQueueWait`, `PluginWork`, `PluginHTTP`).
struct PlaybackStartupTrace {
    enum Stage: String, CaseIterable {
        case selected, resolved, firstBytes = "first_bytes", playerLoaded = "player_loaded", firstFrame = "first_frame"
    }

    private let started = ContinuousClock.now
    private var marks: [Stage: Duration] = [:]
    private var reported = false

    mutating func mark(_ stage: Stage) {
        guard marks[stage] == nil else { return }
        let elapsed = started.duration(to: .now)
        marks[stage] = elapsed
        OSSignposter.player.emitEvent("StartupStage", "stage=\(stage.rawValue, privacy: .public) ms=\(Self.milliseconds(elapsed))")
    }

    mutating func observe(_ snapshot: MediaPipelineSnapshot) {
        let allStarted = !snapshot.tracks.isEmpty && snapshot.tracks.allSatisfy { !$0.stage(.download).completed.isEmpty }
        if allStarted { mark(.firstBytes) }
    }

    mutating func firstFrame(at seconds: Double) {
        guard !reported else { return }
        mark(.firstFrame)
        reported = true
        let fields = Stage.allCases.map { stage in
            "\(stage.rawValue)_ms=\(marks[stage].map { String(Self.milliseconds($0)) } ?? "-")"
        }.joined(separator: " ")
        Logger.player.notice("startup_timing \(fields, privacy: .public) position=\(seconds)")
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
