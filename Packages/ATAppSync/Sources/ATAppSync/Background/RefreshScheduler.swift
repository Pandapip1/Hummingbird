import Foundation

/// Decides when each polled item (a subscribed channel, say) is next due,
/// and keeps polling polite per source (a plugin):
///
/// - Adaptive: an item's interval follows how often it actually updates
///   (half the median gap between its recent updates), within bounds.
/// - Staggered: first checks and every interval are spread by a stable
///   per-item offset, so a hundred channels don't all come due together.
/// - Rate limited: per source, a minimum spacing between requests and a cap
///   per window; failures back the whole source off exponentially, and a
///   source's "retry after" is honoured.
///
/// It is plain data: the app persists it (`Codable`) and drives it.
public struct RefreshScheduler: Codable, Sendable, Equatable {
    public struct Configuration: Codable, Sendable, Equatable {
        public var minimumInterval: TimeInterval = 20 * 60
        public var maximumInterval: TimeInterval = 24 * 3_600
        /// Before an item has shown how often it updates.
        public var initialInterval: TimeInterval = 3 * 3_600
        /// Between two requests to one source.
        public var sourceSpacing: TimeInterval = 2
        /// Requests to one source per `sourceWindow`.
        public var sourceRequestsPerWindow = 30
        public var sourceWindow: TimeInterval = 15 * 60
        public var backoffBase: TimeInterval = 5 * 60
        public var backoffMaximum: TimeInterval = 12 * 3_600
        /// Updates remembered per item for the interval.
        public var history = 8

        public init() {}
    }

    public struct Item: Codable, Sendable, Equatable {
        public let key: String
        public let source: String
        public var nextDue: Date
        public var lastChecked: Date?
        /// When the item was seen to update, newest last.
        public var updates: [Date] = []
        public var interval: TimeInterval
    }

    struct SourceState: Codable, Sendable, Equatable {
        var failures = 0
        var blockedUntil: Date?
        /// Requests in the current window, oldest first.
        var recent: [Date] = []
    }

    public var configuration: Configuration
    public private(set) var items: [String: Item] = [:]
    var sources: [String: SourceState] = [:]

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// The items to poll: new ones are added (due at a staggered point of
    /// their first interval), ones no longer listed are forgotten.
    public mutating func track(_ tracked: [(key: String, source: String)], now: Date) {
        let keys = Set(tracked.map(\.key))
        items = items.filter { keys.contains($0.key) }
        for entry in tracked where items[entry.key] == nil {
            let interval = configuration.initialInterval
            items[entry.key] = Item(key: entry.key, source: entry.source,
                                    nextDue: now.addingTimeInterval(interval * Self.stagger(entry.key)),
                                    interval: interval)
        }
    }

    /// Items due by `now`, most overdue first, skipping sources that are
    /// backing off.
    public func due(now: Date) -> [Item] {
        items.values
            .filter { $0.nextDue <= now && !(sources[$0.source]?.blockedUntil.map { $0 > now } ?? false) }
            .sorted { ($0.nextDue, $0.key) < ($1.nextDue, $1.key) }
    }

    /// When a request to `source` may go out: now, or later to keep the
    /// spacing and the per-window cap. Nil while the source backs off.
    public func nextSlot(for source: String, now: Date) -> Date? {
        let state = sources[source] ?? SourceState()
        if let blocked = state.blockedUntil, blocked > now { return nil }
        var slot = now
        if let last = state.recent.last { slot = max(slot, last.addingTimeInterval(configuration.sourceSpacing)) }
        let window = state.recent.filter { $0 > now.addingTimeInterval(-configuration.sourceWindow) }
        if window.count >= configuration.sourceRequestsPerWindow, let oldest = window.first {
            slot = max(slot, oldest.addingTimeInterval(configuration.sourceWindow))
        }
        return slot
    }

    /// Notes a request to `source` going out at `at`.
    public mutating func recordRequest(source: String, at: Date) {
        var state = sources[source] ?? SourceState()
        state.recent = state.recent.filter { $0 > at.addingTimeInterval(-configuration.sourceWindow) } + [at]
        sources[source] = state
    }

    /// A successful check. `updates` are the item's update times seen in
    /// this check (e.g. its newest uploads); the interval adapts to them.
    public mutating func recordSuccess(key: String, updates: [Date], now: Date) {
        guard var item = items[key] else { return }
        item.lastChecked = now
        item.updates = Array(Set(item.updates + updates).sorted().suffix(configuration.history))
        item.interval = interval(for: item.updates)
        item.nextDue = now.addingTimeInterval(item.interval * (0.9 + 0.2 * Self.stagger(key)))
        items[key] = item
        sources[item.source, default: SourceState()].failures = 0
        sources[item.source]?.blockedUntil = nil
    }

    /// A failed check: the item retries with its source, which backs off
    /// exponentially (or until `retryAfter`, when the source said so).
    public mutating func recordFailure(key: String, retryAfter: TimeInterval? = nil, now: Date) {
        guard var item = items[key] else { return }
        var state = sources[item.source] ?? SourceState()
        state.failures += 1
        let backoff = retryAfter ?? min(configuration.backoffMaximum,
                                        configuration.backoffBase * pow(2, Double(state.failures - 1)))
        state.blockedUntil = now.addingTimeInterval(backoff)
        sources[item.source] = state
        item.lastChecked = now
        item.nextDue = now.addingTimeInterval(backoff)
        items[key] = item
    }

    /// Half the median gap between updates, within the bounds: an item that
    /// updates daily is checked about twice a day.
    func interval(for updates: [Date]) -> TimeInterval {
        guard updates.count >= 2 else { return configuration.initialInterval }
        let gaps = zip(updates.dropFirst(), updates).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return configuration.initialInterval }
        let median = gaps[gaps.count / 2]
        return min(configuration.maximumInterval, max(configuration.minimumInterval, median / 2))
    }

    /// A stable fraction in [0, 1) for `key` (FNV-1a), the same on every launch.
    static func stagger(_ key: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Double(hash % 10_000) / 10_000
    }
}
