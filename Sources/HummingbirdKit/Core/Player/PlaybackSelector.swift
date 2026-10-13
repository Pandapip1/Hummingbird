import Foundation

/// One way to play a video on iOS.
struct PlaybackOption: Identifiable, Hashable {
    enum Kind: Hashable { case live, hls, progressive, generated }
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
        let generated = d.videoSources.filter {
            $0.pluginType == "DashManifestRawSource" && $0.hasGenerate && $0.handle != nil
                && !$0.isWidevine && isPlayableVideoContainer($0)
        }
        let generatedGroups = Dictionary(grouping: generated) { source in
            "\(source.height)|\(source.container.lowercased())|\(source.codec.lowercased())"
        }
        for (identity, sources) in generatedGroups {
            guard let v = bestLanguageSource(sources, language: preferredLanguage) else { continue }
            add(PlaybackOption(id: identity, label: label(for: v), kind: .generated,
                               video: v, audio: nil, height: v.height))
        }
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
        let files = options.filter { $0.kind == .progressive || $0.kind == .generated }
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

    private static func isPlayableVideoContainer(_ source: MediaSource) -> Bool {
        videoContainers.contains(source.container.lowercased())
    }

    static func playableAudioSources(_ sources: [MediaSource]) -> [MediaSource] {
        var seen = Set<String>()
        return sources.filter {
            !$0.url.isEmpty && !$0.isWidevine && !$0.isHLS && !$0.isDash
                && audioContainers.contains($0.container.lowercased())
                && seen.insert($0.id).inserted
        }
    }

    static func bestAudio(_ sources: [MediaSource], language: String?) -> MediaSource? {
        bestLanguageSource(playableAudioSources(sources), language: language)
    }

    static func bestLanguageSource(_ sources: [MediaSource], language: String?) -> MediaSource? {
        var c = sources
        if c.isEmpty { return nil }
        // A video's original track may legitimately be in a different language.
        // Honour the viewer's language before treating "original" as a tie-breaker.
        for lang in [language, "en", "Unknown"].compactMap({ $0 }) where c.contains(where: { $0.language.lowercased().hasPrefix(lang.lowercased()) }) {
            c = c.filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
            break
        }
        if c.contains(where: { $0.original }) { c = c.filter { $0.original } }
        if c.contains(where: { $0.priority }) { c = c.filter { $0.priority } }
        return c.max(by: { $0.bitrate < $1.bitrate })
    }

    static func generatedAudioChoices(for selected: MediaSource, in sources: [MediaSource]) -> [MediaSource] {
        let matches = sources.filter {
            $0.pluginType == "DashManifestRawSource" && $0.hasGenerate && $0.handle != nil
                && $0.height == selected.height
                && $0.container.caseInsensitiveCompare(selected.container) == .orderedSame
                && $0.codec.caseInsensitiveCompare(selected.codec) == .orderedSame
        }
        return languageChoices(matches)
    }

    /// Presents one useful stream per language instead of exposing every codec/bitrate
    /// rendition the plugin returned for that language.
    static func audioChoices(_ sources: [MediaSource]) -> [MediaSource] {
        languageChoices(playableAudioSources(sources))
    }

    private static func languageChoices(_ sources: [MediaSource]) -> [MediaSource] {
        let groups = Dictionary(grouping: sources) {
            let language = $0.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return language.isEmpty ? "unknown" : language
        }
        return groups.values.compactMap { variants in
            var candidates = variants
            if candidates.contains(where: { $0.original }) { candidates = candidates.filter(\.original) }
            if candidates.contains(where: { $0.priority }) { candidates = candidates.filter(\.priority) }
            return candidates.max(by: { $0.bitrate < $1.bitrate })
        }.sorted { audioLabel(for: $0).localizedCaseInsensitiveCompare(audioLabel(for: $1)) == .orderedAscending }
    }

    static func audioLabel(for source: MediaSource) -> String {
        let rawLanguage = source.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = Locale.current.localizedString(forLanguageCode: rawLanguage)
            ?? (rawLanguage.isEmpty || rawLanguage.caseInsensitiveCompare("Unknown") == .orderedSame ? "Unknown" : rawLanguage)
        let original = source.original ? " · Original" : ""
        let quality = source.bitrate > 0 ? " · \(source.bitrate / 1_000) kbps" : ""
        return "\(language)\(original)\(quality)"
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
