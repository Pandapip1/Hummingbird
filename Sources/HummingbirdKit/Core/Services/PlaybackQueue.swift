import Foundation
import Observation

enum QueueRepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one

    var label: String {
        switch self {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    var systemImage: String { self == .one ? "repeat.1" : "repeat" }
}

private struct PersistedPlaybackQueue: Codable {
    var items: [SavedVideo]
    var currentID: String?
    var repeatMode: QueueRepeatMode
    var nextIndexHint: Int?
}

@MainActor
@Observable
final class PlaybackQueue {
    private(set) var items: [SavedVideo]
    private(set) var currentID: String?
    private(set) var repeatMode: QueueRepeatMode
    @ObservationIgnored private var nextIndexHint: Int?

    @ObservationIgnored private let backend: StorageBackend?
    @ObservationIgnored private let storageName: String

    init(backend: StorageBackend? = nil, storageName: String = "playback_queue") {
        self.backend = backend
        self.storageName = storageName
        let saved: PersistedPlaybackQueue?
        if let backend { saved = backend.load(PersistedPlaybackQueue.self, name: storageName) }
        else { saved = Storage.load(PersistedPlaybackQueue.self, name: storageName) }
        items = saved?.items ?? []
        currentID = saved?.currentID
        repeatMode = saved?.repeatMode ?? .off
        nextIndexHint = saved?.nextIndexHint
        if let currentID, !items.contains(where: { $0.id == currentID }) { self.currentID = nil }
    }

    var current: SavedVideo? { currentID.flatMap { id in items.first { $0.id == id } } }

    func beginPlaying(_ video: SavedVideo) {
        if !items.contains(where: { $0.id == video.id }) { items.append(video) }
        currentID = video.id
        nextIndexHint = nil
        persist()
    }

    func enqueue(_ video: SavedVideo) {
        guard !items.contains(where: { $0.id == video.id }) else { return }
        items.append(video)
        persist()
    }

    func playNext(_ video: SavedVideo) {
        items.removeAll { $0.id == video.id }
        let insertion = currentID.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 }
            ?? nextIndexHint ?? 0
        items.insert(video, at: min(insertion, items.count))
        persist()
    }

    func advanceAfterPlayback() -> SavedVideo? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one, let current { return current }
        let index = currentID.flatMap { id in items.firstIndex { $0.id == id } }
        let nextIndex = index.map { $0 + 1 } ?? nextIndexHint ?? 0
        if items.indices.contains(nextIndex) {
            currentID = items[nextIndex].id
        } else if repeatMode == .all {
            currentID = items[0].id
        } else {
            persist()
            return nil
        }
        nextIndexHint = nil
        persist()
        return current
    }

    func select(_ video: SavedVideo) {
        beginPlaying(video)
    }

    func remove(at offsets: IndexSet) {
        let removedCurrentIndex = offsets.first { items.indices.contains($0) && items[$0].id == currentID }
        let cursorBeforeRemoval = removedCurrentIndex ?? (currentID == nil ? nextIndexHint : nil)
        items.remove(atOffsets: offsets)
        if let removedCurrentIndex {
            currentID = nil
            nextIndexHint = removedCurrentIndex
        }
        if let cursorBeforeRemoval {
            let removedBeforeCursor = offsets.filter { $0 < cursorBeforeRemoval }.count
            nextIndexHint = min(max(0, cursorBeforeRemoval - removedBeforeCursor), items.count)
        }
        persist()
    }

    func remove(_ video: SavedVideo) {
        guard let index = items.firstIndex(where: { $0.id == video.id }) else { return }
        remove(at: IndexSet(integer: index))
    }

    func move(from offsets: IndexSet, to destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func moveUp(_ video: SavedVideo) {
        guard let index = items.firstIndex(where: { $0.id == video.id }), index > 0 else { return }
        items.swapAt(index, index - 1)
        persist()
    }

    func moveDown(_ video: SavedVideo) {
        guard let index = items.firstIndex(where: { $0.id == video.id }), index + 1 < items.count else { return }
        items.swapAt(index, index + 1)
        persist()
    }

    func clear() {
        items = []
        currentID = nil
        nextIndexHint = nil
        persist()
    }

    func shuffleUpcoming() {
        guard items.count > 1 else { return }
        let start = currentID.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        guard start < items.endIndex else { return }
        items.replaceSubrange(start..., with: items[start...].shuffled())
        persist()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        persist()
    }

    private func persist() {
        let value = PersistedPlaybackQueue(items: items, currentID: currentID, repeatMode: repeatMode,
                                           nextIndexHint: nextIndexHint)
        if let backend { backend.save(value, name: storageName) }
        else { Storage.save(value, name: storageName) }
    }
}
