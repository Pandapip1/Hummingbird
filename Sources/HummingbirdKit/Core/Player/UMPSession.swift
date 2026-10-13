import Foundation
import DebugKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UMPSessionError: LocalizedError, Sendable {
    case invalidSource, unauthorized, forbidden, protocolFailure(String, Int), protectionExpired, reloadRequired, noProgress, incomplete
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Invalid UMP source"
        case .unauthorized: "UMP playback was not authorized"
        case .forbidden: "UMP playback was forbidden"
        case .protocolFailure(let type, let code): "UMP server error \(type)/\(code)"
        case .protectionExpired: "The playback token expired; refresh the video details"
        case .reloadRequired: "YouTube requested refreshed playback details"
        case .noProgress: "The UMP server stopped producing media"
        case .incomplete: "The UMP presentation was incomplete"
        }
    }

    var isRefreshRequired: Bool {
        switch self {
        case .protectionExpired, .reloadRequired: true
        default: false
        }
    }
}

private struct UMPPending { let header: UMPMediaHeader; var bytes = Data() }
private struct UMPRequestIntent: Sendable { let sequence: Int; let positionMS: UInt64 }

struct UMPPreparationProgress: Sendable {
    let request: UInt64
    let retrySeconds: Int?

    var message: String {
        if let retrySeconds { return "YouTube requested a retry in \(retrySeconds)s (request \(request + 1))" }
        return "Preparing YouTube stream (request \(request))"
    }
}

private struct UMPTrackStore {
    var initialization: Data?
    var segments: [Int: UMPMediaChunk] = [:]
    var finalSegment: Int?
    var presentationDurationMS: Int64?
    var contiguousEnd: Int { var n = segments.keys.min() ?? 0; while segments[n] != nil { n += 1 }; return n - 1 }
    var complete: Bool { guard let finalSegment else { return false }; return initialization != nil && contiguousEnd >= finalSegment }
}

actor UMPSession {
    struct TrackSnapshot: Sendable {
        let format: UMPFormat
        let hasInitialization: Bool
        let segments: [UMPMediaChunk]
        let finalSegment: Int?
        let presentationDuration: Double?
        let isComplete: Bool
    }

    private let source: MediaSource
    private let video: UMPFormat
    private let audio: UMPFormat
    private var endpoint: URL
    private var requestNumber: UInt64 = 0
    private var cookie: Data?
    private var contexts: [Int: Data] = [:]
    private var activeContexts = Set<Int>()
    private var pending: [UInt64: UMPPending] = [:]
    private var tracks: [UMPFormatID: UMPTrackStore] = [:]
    private var emptyResponses = 0
    private var redirects = 0
    private var backoffMS: UInt64 = 0
    private var controlRevision = 0
    private var responseProtectionState: UInt64?
    private var responsePlaybackBlocked = false
    private var tokenOverride: String?
    private var stalledProtectionResponses = 0
    private var terminalError: UMPSessionError?
    private var playbackPositionMS: UInt64 = 0
    private let sessionStartedMS = UInt64(Date().timeIntervalSince1970 * 1_000)
    private var lastResponseMS: UInt64?
    private var cachedRanges: [UMPFormatID: ClosedRange<Int>] = [:]
    private var fetchInFlight: (id: UInt64, task: Task<Void, Error>)?
    private var fetchGeneration: UInt64 = 0
    private let progress: (@Sendable (UMPPreparationProgress) -> Void)?
    private let reloadOnBlockedBootstrap: Bool

    init(source: MediaSource, maximumHeight: Int = 1080, language: String? = nil,
         progress: (@Sendable (UMPPreparationProgress) -> Void)? = nil,
         reloadOnBlockedBootstrap: Bool = false) throws {
        guard let endpoint = URL(string: source.url), source.ustreamerConfig != nil else { throw UMPSessionError.invalidSource }
        let hlsVideos = source.videoFormats.filter(Self.isHLSCompatibleVideo)
        let capped = hlsVideos.filter { $0.height == 0 || $0.height <= maximumHeight }
        guard let video = (capped.isEmpty ? hlsVideos : capped).max(by: { $0.height == $1.height ? $0.bitrate < $1.bitrate : $0.height < $1.height }) else { throw UMPSessionError.invalidSource }
        var audios = source.audioFormats.filter(Self.isHLSCompatibleAudio)
        if let language, audios.contains(where: { $0.language?.lowercased().hasPrefix(language.lowercased()) == true }) { audios = audios.filter { $0.language?.lowercased().hasPrefix(language.lowercased()) == true } }
        if audios.contains(where: \.original) { audios = audios.filter(\.original) }
        guard let audio = audios.max(by: { $0.bitrate < $1.bitrate }) else { throw UMPSessionError.invalidSource }
        self.source = source; self.endpoint = endpoint; self.video = video; self.audio = audio; self.progress = progress
        self.reloadOnBlockedBootstrap = reloadOnBlockedBootstrap
        tracks[UMPFormatID(video)] = UMPTrackStore(); tracks[UMPFormatID(audio)] = UMPTrackStore()
        let decodedToken = Self.base64(source.poToken)
        DebugServer.record("ump", "descriptor_token", fields: [
            "token": source.poToken ?? "<missing>",
            "characters": String(source.poToken?.count ?? 0),
            "decodedBytes": String(decodedToken?.count ?? 0),
            "videoId": source.videoId ?? "<missing>",
            "hasTokenRefresh": String(source.hasRefreshUMPToken),
        ])
    }

    /// Fetches only enough data to publish playable dynamic playlists.
    func prepare(maximumRequests: Int = 12) async throws {
        for _ in 0..<maximumRequests {
            if minimallyReady { return }
            try await pump()
        }
        guard minimallyReady else { throw UMPSessionError.incomplete }
    }

    /// Performs a bounded unit of network work and retains all SABR session state.
    func pump(requests: Int = 1) async throws {
        if let terminalError { throw terminalError }
        for _ in 0..<max(1, min(requests, 4)) {
            do { try await fetchSerialized() }
            catch let error as UMPSessionError { terminalError = error; throw error }
        }
    }

    func snapshots() -> (video: TrackSnapshot, audio: TrackSnapshot) {
        (snapshot(video), snapshot(audio))
    }

    func cacheDescriptor() -> UMPMediaCache.Descriptor {
        let content = source.videoId.flatMap { $0.isEmpty ? nil : $0 } ?? source.ustreamerConfig ?? source.url
        let key = "\(content)|\(video.identity)|\(audio.identity)"
        let lengths = [video.contentLength, audio.contentLength]
        let exact = lengths.allSatisfy { ($0 ?? 0) > 0 }
            ? lengths.compactMap { $0 }.reduce(Int64(0), +)
            : nil
        let duration = [tracks[UMPFormatID(video)]?.presentationDurationMS,
                        tracks[UMPFormatID(audio)]?.presentationDurationMS]
            .compactMap { $0 }.max().map { Double($0) / 1_000 } ?? Double(source.duration)
        let estimated = Int64(ceil(Double(max(1, video.bitrate + audio.bitrate)) * max(1, duration) / 8 * 1.25))
        return UMPMediaCache.Descriptor(
            key: key,
            allocationBytes: exact ?? max(estimated, 16 * 1_024 * 1_024),
            isExact: exact != nil
        )
    }

    func initialization(video isVideo: Bool) async throws -> Data {
        let format = isVideo ? video : audio
        for _ in 0..<4 { if let data = tracks[UMPFormatID(format)]?.initialization { return data }; try await pump() }
        throw UMPSessionError.incomplete
    }

    func segment(video isVideo: Bool, sequence: Int, maximumRequests: Int = 6) async throws -> Data {
        let format = isVideo ? video : audio, id = UMPFormatID(format)
        emptyResponses = 0
        if case .noProgress? = terminalError { terminalError = nil }
        let intent = requestIntent(format: format, sequence: sequence)
        for attempt in 0...maximumRequests {
            if let data = tracks[id]?.segments[sequence]?.data { return data }
            if let final = tracks[id]?.finalSegment, sequence > final { throw UMPSessionError.incomplete }
            if attempt < maximumRequests { try await fetchSerialized(intent: intent) }
        }
        throw UMPSessionError.incomplete
    }

    private func requestIntent(format: UMPFormat, sequence: Int) -> UMPRequestIntent {
        let store = tracks[UMPFormatID(format)]
        let position: UInt64
        if let chunk = store?.segments[sequence] {
            position = UInt64(max(0, chunk.start * 1_000))
        } else if let first = store?.segments.keys.min(), let final = store?.finalSegment,
                  let duration = store?.presentationDurationMS, final >= first {
            let offset = max(0, min(sequence - first, final - first))
            position = UInt64(max(0, duration * Int64(offset) / Int64(max(1, final - first + 1))))
        } else {
            position = playbackPositionMS
        }
        return .init(sequence: sequence, positionMS: position)
    }

    func noteCachedRange(video isVideo: Bool, range: ClosedRange<Int>?) {
        let id = UMPFormatID(isVideo ? video : audio)
        cachedRanges[id] = range
    }

    func replacePoToken(_ token: String) {
        guard !token.isEmpty else { return }
        tokenOverride = token
        DebugServer.record("ump", "continuation_token_ready", fields: [
            "bytes": String(Self.base64(token)?.count ?? 0),
        ])
    }

    /// Exposes the encoded request only to the package's protocol regression
    /// tests. Keeping the assertion at the wire level catches field-number or
    /// enum drift without coupling production code to generated protobufs.
    func requestBodyForTesting() -> Data { requestBody() }

    static func bufferedStreamForTesting(playbackPositionMS: UInt64,
                                         firstSequence: Int,
                                         lastSequence: Int) -> Data {
        bufferedStream(format: nil, playbackPositionMS: playbackPositionMS,
                       firstSequence: firstSequence, lastSequence: lastSequence)
    }

    private var minimallyReady: Bool {
        // AVFoundation does not reliably begin an EVENT presentation from a
        // single media segment. Keep pumping until each rendition has a small
        // contiguous startup window, avoiding a deadlock where the player waits
        // for playlist growth while SABR waits for another client request.
        tracks.values.allSatisfy { store in
            guard store.initialization != nil else { return false }
            if store.complete { return !store.segments.isEmpty }
            return store.contiguousEnd - (store.segments.keys.min() ?? 0) + 1 >= 3
        }
    }
    private var progressMarker: Int {
        tracks.values.reduce(controlRevision) { $0 + $1.segments.count + ($1.initialization == nil ? 0 : 1) }
    }
    private func snapshot(_ format: UMPFormat) -> TrackSnapshot {
        let store = tracks[UMPFormatID(format)] ?? UMPTrackStore()
        var ordered: [UMPMediaChunk] = []
        if var sequence = store.segments.keys.min() {
            while let chunk = store.segments[sequence] { ordered.append(chunk); sequence += 1 }
        }
        return .init(format: format, hasInitialization: store.initialization != nil,
                     segments: ordered, finalSegment: store.finalSegment,
                     presentationDuration: store.presentationDurationMS.map { Double($0) / 1_000 },
                     isComplete: store.complete)
    }

    private func fetch(intent: UMPRequestIntent? = nil) async throws {
        if backoffMS > 0 {
            let delay = backoffMS
            backoffMS = 0
            var remaining = Int((delay + 999) / 1_000)
            while remaining > 0 {
                progress?(.init(request: requestNumber, retrySeconds: remaining))
                let interval = min(delay, 1_000)
                try await Task.sleep(nanoseconds: interval * 1_000_000)
                remaining -= 1
            }
        }
        requestNumber += 1
        progress?(.init(request: requestNumber, retrySeconds: nil))
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []; query.removeAll { $0.name == "rn" }; query.append(.init(name: "rn", value: String(requestNumber))); components.queryItems = query
        guard let url = components.url else { throw UMPSessionError.invalidSource }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = requestBody(intent: intent)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        let userAgent = minimallyReady
            ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36"
            : "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UMPSessionError.invalidSource }
        DebugServer.record("ump", "response", fields: [
            "request": String(requestNumber),
            "status": String(http.statusCode),
            "bytes": String(data.count),
        ])
        if http.statusCode == 401 { throw UMPSessionError.unauthorized }
        if http.statusCode == 403 { throw UMPSessionError.protocolFailure("HTTP", 403) }
        guard (200..<300).contains(http.statusCode) else { throw UMPSessionError.protocolFailure("HTTP", http.statusCode) }
        pending.removeAll(keepingCapacity: true)
        try consume(UMPFraming.decode(data))
        lastResponseMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        pending.removeAll(keepingCapacity: true)
    }

    /// Actor isolation does not span suspension points: simultaneous audio and
    /// video requests can otherwise enter `fetch()` together and corrupt the
    /// shared request number, pending media parts, cookie, and SABR contexts.
    private func fetchSerialized(intent: UMPRequestIntent? = nil) async throws {
        if let flight = fetchInFlight {
            do {
                try await flight.task.value
                if fetchInFlight?.id == flight.id { fetchInFlight = nil }
            } catch {
                if fetchInFlight?.id == flight.id { fetchInFlight = nil }
                throw error
            }
            return
        }
        fetchGeneration &+= 1
        let id = fetchGeneration
        let task = Task { try await self.fetchTrackingProgress(intent: intent) }
        fetchInFlight = (id, task)
        do {
            try await task.value
            if fetchInFlight?.id == id { fetchInFlight = nil }
        } catch {
            if fetchInFlight?.id == id { fetchInFlight = nil }
            throw error
        }
    }

    /// Counts progress once per wire request. Several simultaneous HLS segment
    /// reads may await the same request; counting each waiter made one valid
    /// response look like several empty responses and tripped no-progress.
    private func fetchTrackingProgress(intent: UMPRequestIntent? = nil) async throws {
        let before = progressMarker
        responseProtectionState = nil
        responsePlaybackBlocked = false
        try await fetch(intent: intent)
        let madeProgress = progressMarker != before
        // Context/cookie updates count as protocol progress, but the plugin's
        // first-bootstrap contract still requires a full reload whenever the
        // server emits the playback-blocked notice.
        if reloadOnBlockedBootstrap, responsePlaybackBlocked {
            throw UMPSessionError.reloadRequired
        }
        emptyResponses = madeProgress ? 0 : emptyResponses + 1
        if responseProtectionState == 3, !madeProgress {
            stalledProtectionResponses += 1
            // Give a same-session cookie/context transition one follow-up
            // request, then rebuild the descriptor and attestation together.
            if stalledProtectionResponses >= 2 { throw UMPSessionError.protectionExpired }
        } else {
            stalledProtectionResponses = 0
        }
        if emptyResponses >= 4 { throw UMPSessionError.noProgress }
    }

    private func requestBody(intent: UMPRequestIntent? = nil) -> Data {
        let videoID = UMPFormatID(video), audioID = UMPFormatID(audio)
        let requestPositionMS = intent?.positionMS ?? playbackPositionMS
        let nowMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        var root = ProtoWriter()
        root.message(1) { abr in
            let width = UInt64(max(0, video.width)), height = UInt64(max(0, video.height))
            abr.varint(16, height); abr.varint(18, width); abr.varint(19, height); abr.varint(21, height)
            abr.varint(13, nowMS); abr.varint(23, 104_857); abr.varint(28, requestPositionMS); abr.varint(34, 0)
            if let lastResponseMS { abr.varint(36, nowMS - min(nowMS, lastResponseMS)) }
            abr.varint(39, max(1, nowMS - min(nowMS, sessionStartedMS)))
            abr.varint(46, 1); abr.varint(57, 50); abr.varint(58, 0); abr.varint(59, height)
        }
        // Match YouTube's combined request ordering exactly. Iterating the
        // tracks dictionary here made the first desired stream nondeterministic.
        for id in [videoID, audioID] {
            guard let store = tracks[id], store.initialization != nil else { continue }
            root.bytes(2, id.encode())
            guard let firstSequence = store.segments.keys.min(), let first = store.segments[firstSequence] else { continue }
            var lastSequence = firstSequence
            while store.segments[lastSequence + 1] != nil { lastSequence += 1 }
            if let cached = cachedRanges[id], cached.lowerBound <= lastSequence + 1,
               cached.upperBound >= firstSequence - 1 {
                lastSequence = max(lastSequence, cached.upperBound)
            }
            let advertisedLast = max(first.sequence, (intent?.sequence ?? (lastSequence + 1)) - 1)
            root.bytes(3, Self.bufferedStream(
                format: id,
                playbackPositionMS: requestPositionMS,
                firstSequence: first.sequence,
                lastSequence: advertisedLast
            ))
        }
        if let config = Self.base64(source.ustreamerConfig) { root.bytes(5, config) }
        root.bytes(16, audioID.encode()); root.bytes(17, videoID.encode())
        root.message(19) { context in
            context.message(1) { client in
                if let name = source.clientName { client.varint(16, UInt64(name)) }
                client.string(17, source.clientVersion); client.string(18, source.osName); client.string(19, source.osVersion)
            }
            let encodedToken = tokenOverride ?? source.poToken
            if let token = Self.base64(encodedToken) {
                context.bytes(2, token)
                DebugServer.record("ump", "request_token", fields: [
                    "request": String(requestNumber),
                    "bytes": String(token.count),
                    "base64": token.base64EncodedString(),
                ])
            }
            if let cookie { context.bytes(3, cookie) }
            // The public combined executor does not echo response-managed
            // opcode-57/59 contexts. Binding a freshly minted video POT to
            // bootstrap context state makes the first continuation fail
            // attestation, so native combined requests intentionally carry
            // only client info, POT, and the playback cookie here.
        }
        return root.data
    }

    private static func bufferedStream(format: UMPFormatID?, playbackPositionMS: UInt64,
                                       firstSequence: Int, lastSequence: Int) -> Data {
        var range = ProtoWriter()
        if let format { range.bytes(1, format.encode()) }
        // BufferedStreamInfo: start time, duration, first segment, last segment.
        range.varint(2, 0)
        range.varint(3, playbackPositionMS)
        range.varint(4, UInt64(firstSequence))
        range.varint(5, UInt64(lastSequence))
        return range.data
    }

    private func consume(_ parts: [UMPPart]) throws {
        DebugServer.record("ump", "parts", fields: [
            "request": String(requestNumber),
            "types": Dictionary(grouping: parts, by: \.type).map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ","),
        ])
        for part in parts {
            switch part.type {
            case 20: let header = try UMPMediaHeader(part.payload); guard tracks[header.format] != nil else { throw UMPProtocolError.invalidFormat }; pending[header.id] = UMPPending(header: header)
            case 21: var o = 0; let id = try UMPFraming.decodeCompact(part.payload, &o); guard pending[id] != nil else { continue }; pending[id]!.bytes.append(part.payload[o...])
            case 22:
                var o = 0; let id = try UMPFraming.decodeCompact(part.payload, &o); guard let item = pending.removeValue(forKey: id) else { continue }; if let expected = item.header.expectedLength, expected != item.bytes.count { continue }; store(item)
            case 35:
                let f = try ProtoReader(part.payload).fields()
                if let replacement = f.first(where: { $0.number == 7 })?.bytes, !replacement.isEmpty, replacement != cookie {
                    cookie = replacement
                    controlRevision &+= 1
                }
                backoffMS = f.first { $0.number == 4 }?.varint ?? 0
            case 42:
                let metadata = try UMPInitMetadata(part.payload)
                guard let previous = tracks[metadata.format] else { throw UMPProtocolError.invalidFormat }
                if previous.finalSegment != metadata.finalSegment
                    || previous.presentationDurationMS != metadata.mediaEndMS {
                    tracks[metadata.format]?.finalSegment = metadata.finalSegment
                    tracks[metadata.format]?.presentationDurationMS = metadata.mediaEndMS
                    controlRevision &+= 1
                }
            case 43:
                let fields = try ProtoReader(part.payload).fields()
                if let bytes = fields.first(where: { $0.number == 1 })?.bytes,
                   let string = String(data: bytes, encoding: .utf8), let url = URL(string: string) {
                    redirects += 1
                    guard redirects <= 5 else { throw UMPSessionError.noProgress }
                    if endpoint != url { endpoint = url; controlRevision &+= 1 }
                }
            case 44:
                let f = try ProtoReader(part.payload).fields()
                let type = f.first { $0.number == 1 }?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
                throw UMPSessionError.protocolFailure(type, Int(f.first { $0.number == 2 }?.varint ?? 0))
            case 46: throw UMPSessionError.reloadRequired
            case 57:
                let fields = try ProtoReader(part.payload).fields()
                let type = Int(fields.first { $0.number == 1 }?.varint ?? 0)
                if let value = fields.first(where: { $0.number == 3 })?.bytes, contexts[type] != value {
                    contexts[type] = value
                    controlRevision &+= 1
                }
                if (fields.first { $0.number == 4 }?.varint ?? 0) != 0,
                   activeContexts.insert(type).inserted {
                    controlRevision &+= 1
                }
            case 58:
                let fields = try ProtoReader(part.payload).fields()
                let state = fields.first(where: { $0.number == 1 })?.varint ?? 0
                responseProtectionState = state
                // This is session state, not a terminal response. In
                // particular, an attestation-required response can also carry
                // a replacement cookie/context in adjacent parts. Keep those
                // values and let the next request use them; terminating here
                // makes every clean replacement session repeat the same
                // bootstrap response forever.
                DebugServer.record("ump", "protection_state", fields: [
                    "request": String(requestNumber),
                    "state": String(state),
                ])
            case 59:
                let policy = try ProtoReader(part.payload).fields()
                for field in policy where (1...3).contains(field.number) {
                    for value in try field.repeatedVarints() {
                        let type = Int(value)
                        if field.number == 1, activeContexts.insert(type).inserted {
                            controlRevision &+= 1
                        } else if field.number == 2, activeContexts.remove(type) != nil {
                            controlRevision &+= 1
                        } else if field.number == 3 {
                        if contexts.removeValue(forKey: type) != nil { controlRevision &+= 1 }
                        if activeContexts.remove(type) != nil { controlRevision &+= 1 }
                        }
                    }
                }
            case 67:
                let f = try ProtoReader(part.payload).fields()
                if f.first(where: { $0.number == 1 })?.varint == 1 {
                    responsePlaybackBlocked = true
                    // This is a playback-blocked UI notification, not a terminal
                    // transport result. Bootstrap responses can include it beside
                    // the cookie/context required by the next request.
                    DebugServer.record("ump", "playback_blocked_notice", fields: ["request": String(requestNumber)])
                }
            default: continue
            }
        }
    }

    private func store(_ item: UMPPending) {
        redirects = 0
        let kind = item.header.format == UMPFormatID(video) ? "video"
            : item.header.format == UMPFormatID(audio) ? "audio" : "unselected"
        if item.header.isInit {
            tracks[item.header.format]?.initialization = item.bytes
            DebugServer.record("ump", "media_received", fields: [
                "kind": kind, "sequence": "init", "bytes": String(item.bytes.count),
            ])
            return
        }
        let timing = item.header.tickRange.flatMap { $0.timescale > 0 ? (Double($0.start) / Double($0.timescale), Double($0.duration) / Double($0.timescale)) : nil } ?? (Double(item.header.startMS) / 1000, Double(item.header.durationMS) / 1000)
        tracks[item.header.format]?.segments[item.header.sequence] = .init(sequence: item.header.sequence, start: timing.0, duration: timing.1, data: item.bytes)
        DebugServer.record("ump", "media_received", fields: [
            "kind": kind,
            "sequence": String(item.header.sequence),
            "start": String(timing.0),
            "bytes": String(item.bytes.count),
        ])
    }

    private static func base64(_ string: String?) -> Data? { guard var string, !string.isEmpty else { return nil }; string = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); string += String(repeating: "=", count: (4 - string.count % 4) % 4); return Data(base64Encoded: string, options: .ignoreUnknownCharacters) }

    private static func isHLSCompatibleVideo(_ format: UMPFormat) -> Bool {
        guard format.mimeType.lowercased() == "video/mp4" else { return false }
        let codec = format.codecs?.lowercased() ?? ""
        return codec.hasPrefix("avc1") || codec.hasPrefix("avc3")
            || codec.hasPrefix("hvc1") || codec.hasPrefix("hev1")
    }

    private static func isHLSCompatibleAudio(_ format: UMPFormat) -> Bool {
        guard format.mimeType.lowercased() == "audio/mp4" else { return false }
        let codec = format.codecs?.lowercased() ?? ""
        return codec.hasPrefix("mp4a") || codec.hasPrefix("ac-3") || codec.hasPrefix("ec-3")
    }
}
