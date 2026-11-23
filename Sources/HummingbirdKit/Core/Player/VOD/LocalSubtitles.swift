import Foundation

/// A plugin's subtitle track, served to the player as an HLS `SUBTITLES`
/// rendition of the local presentation (a one-segment WebVTT playlist).
/// The platform player then lists, selects and draws it like any other
/// legible track: styled per the system's caption settings
/// (MACaptionAppearance), chosen automatically per the viewer's language and
/// accessibility preferences, and shown in Picture in Picture.
struct LocalSubtitle: Sendable {
    var name: String
    var language: String?
    /// `CHARACTERISTICS` UTIs (`public.accessibility.transcribes-spoken-dialog`…), when known.
    var characteristics: String?
    /// Loads the subtitle as WebVTT (fetched once, when the player first asks).
    var webVTT: @Sendable () async throws -> String

    /// Its rendition in the local master (paired there with its playlist name).
    var rendition: HLSPlaylist.Rendition {
        HLSPlaylist.Rendition(groupID: LocalSubtitle.groupID, name: name, language: language, isDefault: false,
                              uri: nil, autoselect: true, forced: false, characteristics: characteristics)
    }

    static let groupID = "subs"

    /// Playlist and text names of subtitle `index` within a presentation.
    static func playlistName(_ index: Int) -> String { "s\(index).m3u8" }
    static func textName(_ index: Int) -> String { "s\(index).vtt" }

    /// The one-segment media playlist for a subtitle covering `duration` seconds.
    static func mediaPlaylist(textName: String, duration: Double) -> String {
        let length = max(duration, 1)
        return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(length)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
            + "#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(String(format: "%.6f", length)),\n\(textName)\n#EXT-X-ENDLIST\n"
    }

    /// Adds `subtitles` to `presentation` (playlists and texts) and returns
    /// their renditions with playlist names, for the local master.
    static func add(_ subtitles: [LocalSubtitle], duration: Double,
                    to presentation: inout LocalMediaServer.Presentation) -> [(HLSPlaylist.Rendition, String)] {
        subtitles.enumerated().map { index, subtitle in
            let playlist = playlistName(index), text = textName(index)
            presentation.playlists[playlist] = mediaPlaylist(textName: text, duration: duration)
            presentation.texts[text] = LocalMediaServer.ServedText(contentType: "text/vtt", text: OnceText(subtitle.webVTT))
            return (subtitle.rendition, playlist)
        }
    }

    /// WebVTT for `text` (WebVTT kept as is; SubRip converted).
    static func webVTT(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("WEBVTT") { return text }
        var out = "WEBVTT\n\n"
        for cue in SubtitleParser.parse(text) {
            out += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let h = milliseconds / 3_600_000, m = milliseconds / 60_000 % 60, s = milliseconds / 1000 % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, milliseconds % 1000)
    }
}

/// Text produced once, on first request, and kept: later requests (and
/// concurrent ones) share the first load; a failed load is tried again.
actor OnceText {
    private let load: @Sendable () async throws -> String
    private var task: Task<String, Error>?

    init(_ load: @escaping @Sendable () async throws -> String) {
        self.load = load
    }

    func value() async throws -> String {
        if let task {
            do { return try await task.value } catch { self.task = nil; throw error }
        }
        let load = load
        let started = Task { try await load() }
        task = started
        do { return try await started.value } catch { task = nil; throw error }
    }
}
