import Foundation

/// How long the periodic sync pass waits: 30 seconds after anything
/// happened, doubling while passes find nothing new, up to 10 minutes.
struct SyncBackoff: Equatable, Sendable {
    static let first: Duration = .seconds(30)
    static let cap: Duration = .seconds(600)

    private(set) var interval = SyncBackoff.first

    /// A pass found nothing new (or was skipped to save energy).
    mutating func idle() { interval = min(interval * 2, Self.cap) }

    /// Something happened: a local edit, the app coming to the front, a
    /// device appearing, a pass that brought changes.
    mutating func reset() { interval = Self.first }
}

/// Runs the periodic sync pass while the app is active, backing off while
/// nothing changes. Local edits sync on their own (the mutation handler), so
/// this only catches what other devices did; it never runs while the app is
/// inactive or in the background (background sync is the system's
/// background-refresh window), nor while non-urgent work should wait.
@MainActor
final class PeriodicSync {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private var backoff = SyncBackoff()
    private var active = true
    private var task: Task<Void, Never>?
    /// One pass; true when it brought or applied anything new.
    private let pass: @MainActor () async -> Bool
    private let defers: @Sendable () -> Bool
    private let sleep: Sleep

    /// `sleep` waits between passes (tests replace it); by default with a
    /// quarter of the interval as tolerance, so the system can coalesce it.
    init(pass: @escaping @MainActor () async -> Bool, defers: @escaping @Sendable () -> Bool,
         sleep: @escaping Sleep = { try await Task.sleep(for: $0, tolerance: $0 / 4) }) {
        self.pass = pass
        self.defers = defers
        self.sleep = sleep
    }

    /// The wait before the next pass.
    var interval: Duration { backoff.interval }
    var isRunning: Bool { task != nil }

    func start() { schedule() }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Foreground: sync soon and keep going. Inactive or background: stop.
    func setActive(_ isActive: Bool) {
        active = isActive
        if isActive {
            backoff.reset()
            schedule()
        } else {
            stop()
        }
    }

    /// Something happened (a local edit, a device appeared or left): start
    /// again from the shortest wait.
    func nudge() {
        backoff.reset()
        if active { schedule() }
    }

    private func schedule() {
        task?.cancel()
        guard active else { task = nil; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.backoff.interval, let sleep = self?.sleep else { return }
                do { try await sleep(wait) } catch { return }
                guard let self, !Task.isCancelled, self.active else { return }
                if self.defers() {
                    self.backoff.idle()
                    continue
                }
                let changed = await self.pass()
                guard !Task.isCancelled else { return }
                if changed { self.backoff.reset() } else { self.backoff.idle() }
            }
        }
    }
}
