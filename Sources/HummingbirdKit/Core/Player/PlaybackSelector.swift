import Foundation

/// One way to play a video on iOS.
struct PlaybackOption: Identifiable, Hashable {
    enum Kind: Hashable { case live, hls, progressive }
    var id: String
    var label: String
    var kind: Kind
    var video: MediaSource
    var audio: MediaSource?
    var height: Int
}

/// Chooses among the sources a plugin offers, keeping only what AVPlayer can play: HLS and MP4-family files.
/// WebM/VP9/Opus, DASH and Widevine-protected streams are skipped (they need a different player or DRM support).
enum PlaybackSelector {
    static let videoContainers: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v", "video/m4v", "video/3gpp", "video/mov"]
    static let audioContainers: Set<String> = ["audio/mp4", "audio/m4a", "audio/x-m4a", "audio/mpeg", "audio/mp3", "audio/aac", "audio/x-aac"]

    static func options(for d: VideoDetails, preferredLanguage: String? = nil) -> [PlaybackOption] {
        var out: [PlaybackOption] = []
        var seen = Set<String>()
        func add(_ o: PlaybackOption) { if seen.insert(o.id).inserted { out.append(o) } }

        if let live = d.live, !live.url.isEmpty, !live.isWidevine, !live.isDash {
            add(PlaybackOption(id: "live|\(live.url)", label: "Live", kind: .live, video: live, audio: nil, height: Int.max))
        }
        let hlsSources = ([d.hls].compactMap { $0 } + d.videoSources.filter { $0.isHLS }).filter { !$0.url.isEmpty && !$0.isWidevine }
        for s in hlsSources {
            add(PlaybackOption(id: "hls|\(s.url)", label: s.name.isEmpty ? "Auto (adaptive)" : s.name, kind: .hls, video: s, audio: nil, height: Int.max - 1))
        }

        let audio = bestAudio(d.audioSources, language: preferredLanguage)
        for v in d.videoSources where !v.isHLS && !v.isDash && !v.isWidevine && !v.url.isEmpty && isPlayableVideo(v) {
            if d.isUnmuxed {
                guard let audio else { continue }
                add(PlaybackOption(id: "prog|\(v.url)|\(audio.url)", label: label(for: v), kind: .progressive, video: v, audio: audio, height: v.height))
            } else {
                add(PlaybackOption(id: "prog|\(v.url)", label: label(for: v), kind: .progressive, video: v, audio: nil, height: v.height))
            }
        }
        return out
    }

    /// Picks the default: live stream first; otherwise adaptive HLS when allowed; otherwise the tallest file at or under `maxHeight`.
    static func best(_ options: [PlaybackOption], maxHeight: Int, preferAdaptive: Bool) -> PlaybackOption? {
        if let live = options.first(where: { $0.kind == .live }) { return live }
        if preferAdaptive, let hls = options.first(where: { $0.kind == .hls }) { return hls }
        let files = options.filter { $0.kind == .progressive }
        let capped = files.filter { $0.height <= maxHeight || $0.height == 0 }
        if let pick = capped.max(by: { $0.height < $1.height }) { return pick }
        if let pick = files.min(by: { $0.height < $1.height }) { return pick }
        return options.first(where: { $0.kind == .hls })
    }

    private static func isPlayableVideo(_ s: MediaSource) -> Bool {
        let c = s.container.lowercased()
        if !c.isEmpty { return videoContainers.contains(c) }
        let path = URL(string: s.url)?.pathExtension.lowercased() ?? ""
        return ["mp4", "m4v", "mov"].contains(path)
    }

    private static func bestAudio(_ sources: [MediaSource], language: String?) -> MediaSource? {
        var c = sources.filter { !$0.url.isEmpty && !$0.isWidevine && !$0.isHLS && !$0.isDash && audioContainers.contains($0.container.lowercased()) }
        if c.isEmpty { return nil }
        if c.contains(where: { $0.priority }) { c = c.filter { $0.priority } }
        if c.contains(where: { $0.original }) { c = c.filter { $0.original } }
        for lang in [language, "en", "Unknown"].compactMap({ $0 }) where c.contains(where: { $0.language.lowercased().hasPrefix(lang.lowercased()) }) {
            c = c.filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
            break
        }
        return c.max(by: { $0.bitrate < $1.bitrate })
    }

    private static func label(for v: MediaSource) -> String {
        if v.height > 0 { return "\(v.height)p" + (v.name.isEmpty || v.name == "\(v.height)p" ? "" : " · \(v.name)") }
        return v.name.isEmpty ? "Video" : v.name
    }
}

// MARK: - Subtitles

struct SubtitleCue: Hashable { var start: Double; var end: Double; var text: String }

enum SubtitleParser {
    /// Parses WebVTT and SubRip text into cues.
    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let s = seconds(parts[0]), let e = seconds(parts[1]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !body.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // "00:01:02.500", "01:02.500", "00:01:02,500 position:..." -> seconds
    private static func seconds(_ s: String) -> Double? {
        let token = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; total = total * 60 + v }
        return total
    }
}
