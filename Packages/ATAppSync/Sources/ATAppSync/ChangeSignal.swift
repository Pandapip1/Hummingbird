import Foundation
import Synchronization

/// Tells any number of listeners that some state changed, without saying
/// what: listeners re-read the state they show. A listener that falls behind
/// sees one pending change rather than a backlog.
final class AppSyncChangeSignal: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send() {
        let listeners = continuations.withLock { Array($0.values) }
        for listener in listeners { listener.yield() }
    }
}
