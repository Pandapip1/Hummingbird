import Foundation
import Synchronization

/// Whether work that can wait should wait: the device is saving energy (Low
/// Power Mode, a power-saver profile) or running hot. One policy every
/// component consults (downloads nobody watches, transcoding, bulk sync,
/// idle preparation, cache scans) instead of each reading the platform's
/// power state; the app feeds it from SwiftOpenUI's `PowerState`.
final class BackgroundWorkPolicy: Sendable {
    private struct State {
        var defers = false
        var observers: [@Sendable (Bool) -> Void] = []
        var following = false
    }
    private let state = Mutex(State())

    /// Non-urgent work should wait now.
    var defersNonUrgentWork: Bool { state.withLock { $0.defers } }

    /// Calls `observer` now and whenever the answer changes.
    func observe(_ observer: @escaping @Sendable (Bool) -> Void) {
        let defers = state.withLock { state in
            state.observers.append(observer)
            return state.defers
        }
        observer(defers)
    }

    /// True once: the first caller subscribes the policy to the platform.
    func claimFollowing() -> Bool {
        state.withLock { state in
            defer { state.following = true }
            return !state.following
        }
    }

    func update(defersNonUrgentWork defers: Bool) {
        let observers = state.withLock { state -> [@Sendable (Bool) -> Void] in
            guard state.defers != defers else { return [] }
            state.defers = defers
            return state.observers
        }
        for observer in observers { observer(defers) }
    }
}
