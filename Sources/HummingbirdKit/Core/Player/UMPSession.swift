import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum UMPSessionError: LocalizedError, Sendable {
    case invalidSource, unauthorized, forbidden, protocolFailure(String, Int), protectionExpired, noProgress, incomplete
    var errorDescription: String? {
        switch self {
        case .invalidSource: "Invalid UMP source"
        case .unauthorized: "UMP playback was not authorized"
        case .forbidden: "UMP playback was forbidden"
        case .protocolFailure(let type, let code): "UMP server error \(type)/\(code)"
        case .protectionExpired: "The playback token expired; refresh the video details"
        case .noProgress: "The UMP server stopped producing media"
        case .incomplete: "The UMP presentation was incomplete"
        }
    }
}

private struct UMPPending { let header: UMPMediaHeader; var bytes = Data() }

private struct UMPTrackStore {
    var initialization: Data?
    var segments: [Int: UMPMediaChunk] = [:]
    var finalSegment: Int?
    var contiguousEnd: Int { var n = segments.keys.min() ?? 0; while segments[n] != nil { n += 1 }; return n - 1 }
    var complete: Bool { guard let finalSegment else { return false }; return initialization != nil && contiguousEnd >= finalSegment }
}

actor UMPSession {
    struct TrackSnapshot: Sendable {
        let format: UMPFormat
        let hasInitialization: Bool
        let segments: [UMPMediaChunk]
        let finalSegment: Int?
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
    private var terminalError: UMPSessionError?

    init(source: MediaSource, maximumHeight: Int = 1080, language: String? = nil) throws {
        guard let endpoint = URL(string: source.url), source.ustreamerConfig != nil else { throw UMPSessionError.invalidSource }
        let capped = source.videoFormats.filter { $0.height == 0 || $0.height <= maximumHeight }
        guard let video = (capped.isEmpty ? source.videoFormats : capped).max(by: { $0.height == $1.height ? $0.bitrate < $1.bitrate : $0.height < $1.height }) else { throw UMPSessionError.invalidSource }
        var audios = source.audioFormats
        if let language, audios.contains(where: { $0.language?.lowercased().hasPrefix(language.lowercased()) == true }) { audios = audios.filter { $0.language?.lowercased().hasPrefix(language.lowercased()) == true } }
        if audios.contains(where: \.original) { audios = audios.filter(\.original) }
        guard let audio = audios.max(by: { $0.bitrate < $1.bitrate }) else { throw UMPSessionError.invalidSource }
        self.source = source; self.endpoint = endpoint; self.video = video; self.audio = audio
        tracks[UMPFormatID(video)] = UMPTrackStore(); tracks[UMPFormatID(audio)] = UMPTrackStore()
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
            let before = progressCount
            do { try await fetch() }
            catch let error as UMPSessionError { terminalError = error; throw error }
            emptyResponses = progressCount == before ? emptyResponses + 1 : 0
            if emptyResponses >= 4 { terminalError = .noProgress; throw UMPSessionError.noProgress }
        }
    }

    func snapshots() -> (video: TrackSnapshot, audio: TrackSnapshot) {
        (snapshot(video), snapshot(audio))
    }

    func initialization(video isVideo: Bool) async throws -> Data {
        let format = isVideo ? video : audio
        for _ in 0..<4 { if let data = tracks[UMPFormatID(format)]?.initialization { return data }; try await pump() }
        throw UMPSessionError.incomplete
    }

    func segment(video isVideo: Bool, sequence: Int, maximumRequests: Int = 6) async throws -> Data {
        let format = isVideo ? video : audio, id = UMPFormatID(format)
        for attempt in 0...maximumRequests {
            if let data = tracks[id]?.segments[sequence]?.data { return data }
            if let final = tracks[id]?.finalSegment, sequence > final { throw UMPSessionError.incomplete }
            if attempt < maximumRequests { try await pump() }
        }
        throw UMPSessionError.incomplete
    }

    private var minimallyReady: Bool {
        tracks.values.allSatisfy { $0.initialization != nil && !$0.segments.isEmpty }
    }
    private var progressCount: Int {
        tracks.values.reduce(0) { $0 + $1.segments.count + ($1.initialization == nil ? 0 : 1) }
    }
    private func snapshot(_ format: UMPFormat) -> TrackSnapshot {
        let store = tracks[UMPFormatID(format)] ?? UMPTrackStore()
        var ordered: [UMPMediaChunk] = []
        if var sequence = store.segments.keys.min() {
            while let chunk = store.segments[sequence] { ordered.append(chunk); sequence += 1 }
        }
        return .init(format: format, hasInitialization: store.initialization != nil,
                     segments: ordered, finalSegment: store.finalSegment, isComplete: store.complete)
    }

    private func fetch() async throws {
        if backoffMS > 0 { try await Task.sleep(nanoseconds: min(backoffMS, 10_000) * 1_000_000); backoffMS = 0 }
        requestNumber += 1
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []; query.removeAll { $0.name == "rn" }; query.append(.init(name: "rn", value: String(requestNumber))); components.queryItems = query
        guard let url = components.url else { throw UMPSessionError.invalidSource }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = requestBody()
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.yt-ump", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UMPSessionError.invalidSource }
        if http.statusCode == 401 { throw UMPSessionError.unauthorized }; if http.statusCode == 403 { throw UMPSessionError.forbidden }
        guard (200..<300).contains(http.statusCode) else { throw UMPSessionError.protocolFailure("HTTP", http.statusCode) }
        try consume(UMPFraming.decode(data))
    }

    private func requestBody() -> Data {
        let videoID = UMPFormatID(video), audioID = UMPFormatID(audio)
        var root = ProtoWriter()
        root.message(1) { abr in
            abr.varint(18, 1920); abr.varint(19, 1080); abr.varint(23, 2_000_000)
            abr.varint(28, 0); abr.varint(29, 0); abr.varint(34, 1); abr.varint(36, 0); abr.varint(39, 0)
            abr.varint(40, 3); abr.varint(44, 1); abr.varint(46, audio.isDrc ? 1 : 0); abr.varint(57, 0); abr.varint(58, 1); abr.varint(59, UInt64(max(0, video.height)))
            abr.fixed32(285, Float(1).bitPattern)
        }
        for (id, store) in tracks where store.initialization != nil {
            root.bytes(2, id.encode())
            guard let firstSequence = store.segments.keys.min(), let first = store.segments[firstSequence] else { continue }
            var last = first, nextSequence = firstSequence + 1
            while let chunk = store.segments[nextSequence] { last = chunk; nextSequence += 1 }
            root.message(3) { range in
                range.bytes(1, id.encode()); range.varint(2, UInt64(max(0, Int64(first.start * 1000)))); range.varint(3, UInt64(max(0, Int64((last.start + last.duration - first.start) * 1000))))
                range.varint(4, UInt64(first.sequence)); range.varint(5, UInt64(last.sequence))
                range.message(6) { time in time.sint(1, Int64(first.start * 1000)); time.sint(2, Int64((last.start + last.duration - first.start) * 1000)); time.sint(3, 1000) }
            }
        }
        if let config = Self.base64(source.ustreamerConfig) { root.bytes(5, config) }
        root.bytes(16, audioID.encode()); root.bytes(17, videoID.encode())
        root.message(19) { context in
            context.message(1) { client in
                if let name = source.clientName { client.varint(16, UInt64(name)) }
                client.string(17, source.clientVersion); client.string(18, source.osName); client.string(19, source.osVersion)
            }
            if let token = Self.base64(source.poToken) { context.bytes(2, token) }
            if let cookie { context.bytes(3, cookie) }
            for type in activeContexts.sorted() { if let value = contexts[type] { context.message(5) { $0.varint(1, UInt64(type)); $0.bytes(2, value) } } }
            for type in contexts.keys.sorted() where !activeContexts.contains(type) { context.varint(6, UInt64(type)) }
        }
        return root.data
    }

    private func consume(_ parts: [UMPPart]) throws {
        for part in parts {
            switch part.type {
            case 20: let header = try UMPMediaHeader(part.payload); guard tracks[header.format] != nil else { throw UMPProtocolError.invalidFormat }; pending[header.id] = UMPPending(header: header)
            case 21: var o = 0; let id = try UMPFraming.decodeCompact(part.payload, &o); guard pending[id] != nil else { continue }; pending[id]!.bytes.append(part.payload[o...])
            case 22:
                var o = 0; let id = try UMPFraming.decodeCompact(part.payload, &o); guard var item = pending.removeValue(forKey: id) else { continue }; item.bytes.append(part.payload[o...]); if let expected = item.header.expectedLength, expected != item.bytes.count { continue }; store(item)
            case 35:
                let f = try ProtoReader(part.payload).fields(); cookie = f.first { $0.number == 7 }?.bytes; backoffMS = f.first { $0.number == 4 }?.varint ?? 0
            case 42:
                let metadata = try UMPInitMetadata(part.payload); guard tracks[metadata.format] != nil else { throw UMPProtocolError.invalidFormat }; tracks[metadata.format]?.finalSegment = metadata.finalSegment
            case 43:
                let f = try ProtoReader(part.payload).fields(); if let b = f.first(where: { $0.number == 1 })?.bytes, let s = String(data: b, encoding: .utf8), let url = URL(string: s) { redirects += 1; guard redirects <= 5 else { throw UMPSessionError.noProgress }; endpoint = url }
            case 44:
                let f = try ProtoReader(part.payload).fields()
                let type = f.first { $0.number == 1 }?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
                throw UMPSessionError.protocolFailure(type, Int(f.first { $0.number == 2 }?.varint ?? 0))
            case 57:
                let f = try ProtoReader(part.payload).fields(); let type = Int(f.first { $0.number == 1 }?.varint ?? 0); if let value = f.first(where: { $0.number == 3 })?.bytes { contexts[type] = value }; if (f.first { $0.number == 4 }?.varint ?? 0) != 0 { activeContexts.insert(type) }
            case 58:
                let f = try ProtoReader(part.payload).fields(); if f.first(where: { $0.number == 1 })?.varint == 3 { throw UMPSessionError.protectionExpired }
            case 59:
                let policy = try ProtoReader(part.payload).fields()
                policy.filter { $0.number == 1 }.forEach { if let v = $0.varint { activeContexts.insert(Int(v)) } }
                policy.filter { $0.number == 2 }.forEach { if let v = $0.varint { activeContexts.remove(Int(v)) } }
                policy.filter { $0.number == 3 }.forEach { if let v = $0.varint { contexts[Int(v)] = nil; activeContexts.remove(Int(v)) } }
            case 67:
                let f = try ProtoReader(part.payload).fields(); if f.first(where: { $0.number == 1 })?.varint == 1 { throw UMPSessionError.forbidden }
            default: continue
            }
        }
    }

    private func store(_ item: UMPPending) {
        if item.header.isInit { tracks[item.header.format]?.initialization = item.bytes; return }
        let timing = item.header.tickRange.flatMap { $0.timescale > 0 ? (Double($0.start) / Double($0.timescale), Double($0.duration) / Double($0.timescale)) : nil } ?? (Double(item.header.startMS) / 1000, Double(item.header.durationMS) / 1000)
        tracks[item.header.format]?.segments[item.header.sequence] = .init(sequence: item.header.sequence, start: timing.0, duration: timing.1, data: item.bytes)
    }

    private static func base64(_ string: String?) -> Data? { guard var string, !string.isEmpty else { return nil }; string = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); string += String(repeating: "=", count: (4 - string.count % 4) % 4); return Data(base64Encoded: string, options: .ignoreUnknownCharacters) }
}
