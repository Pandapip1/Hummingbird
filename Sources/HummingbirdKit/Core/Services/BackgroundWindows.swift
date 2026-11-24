import ATAppSync
import Foundation
import os
import PlatformSupport

/// What Hummingbird does in the time the system gives it while it isn't in
/// use (SwiftOpenUI's `BackgroundRefresh`: BackgroundTasks on iOS and
/// friends, a timer while the app runs elsewhere). One behaviour everywhere:
///
/// 1. sync the profile (pull and push, as a scheduled pass),
/// 2. refill the synced cache from trusted devices,
/// 3. check subscribed channels for new videos (notifying where asked),
/// 4. in the longer maintenance window, re-key the cache after a key
///    epoch change and save it.
///
/// Each step runs within the window's deadline; what doesn't fit is left
/// for the next window. Nothing runs while non-urgent work should wait
/// (Low Power Mode, a hot device).
public enum HummingbirdBackgroundWork {
    static let refreshIdentifier = "com.eightybps.hummingbird.refresh"
    static let maintenanceIdentifier = "com.eightybps.hummingbird.maintenance"
    /// The soonest the next short window is asked for.
    static let refreshSpacing: TimeInterval = 30 * 60
    static let maintenanceSpacing: TimeInterval = 6 * 3_600

    /// Registers the windows. Call once at launch, before the app finishes
    /// launching (iOS requires it).
    @MainActor
    public static func registerAtLaunch() {
        BackgroundRefresh.register(refreshIdentifier, kind: .refresh) { window in
            await run(window, maintenance: false)
        }
        BackgroundRefresh.register(maintenanceIdentifier, kind: .processing(requiresExternalPower: true)) { window in
            await run(window, maintenance: true)
        }
    }

    /// Asks for the next windows (after launch, and after each window).
    @MainActor
    static func scheduleNext() {
        do {
            try BackgroundRefresh.schedule(refreshIdentifier, earliest: Date().addingTimeInterval(refreshSpacing))
            try BackgroundRefresh.schedule(maintenanceIdentifier, earliest: Date().addingTimeInterval(maintenanceSpacing))
        } catch {
            Logger.background.notice("background_schedule_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    @MainActor
    private static func run(_ window: BackgroundRefresh.Window, maintenance: Bool) async -> Bool {
        defer { scheduleNext() }
        // A window on a cold background launch, before any profile opened:
        // nothing to do this time.
        guard let session = BackgroundSession.current else { return true }
        return await session.runWindow(deadline: window.deadline, maintenance: maintenance)
    }
}

/// The profile background windows work for: the first window that opened
/// it, while it stays open. One per process, so a video is announced once.
@MainActor
final class BackgroundSession {
    private(set) static weak var current: BackgroundSession?

    private let stores: AppDataStores
    private let profileAccount: ProfileAccountService
    private let poller: SubscriptionPoller
    private let cache: CacheJournal?

    init(stores: AppDataStores, profileAccount: ProfileAccountService, poller: SubscriptionPoller, cache: CacheJournal?) {
        self.stores = stores
        self.profileAccount = profileAccount
        self.poller = poller
        self.cache = cache
    }

    /// Makes this the session background windows use, unless another is
    /// already; asks for the first windows.
    func claim() {
        guard Self.current == nil else { return }
        Self.current = self
        HummingbirdBackgroundWork.scheduleNext()
    }

    enum Step: Hashable, Sendable { case sync, cache, subscriptions, rekey }

    /// One window's work, within `deadline`. True when it all ran.
    func runWindow(deadline: ContinuousClock.Instant, maintenance: Bool) async -> Bool {
        guard !stores.backgroundWork.defersNonUrgentWork else {
            Logger.background.notice("background_window_skipped reason=saving_energy")
            return true
        }
        let budget = BackgroundBudget(deadline: deadline)
        var steps: [Step] = [.sync, .cache, .subscriptions]
        if maintenance { steps.append(.rekey) }
        let report = await BackgroundRunner.run(steps, budget: budget) { [weak self] step in
            try await self?.perform(step, budget: budget)
        }
        cache?.persist()
        Logger.background.notice("background_window completed=\(report.completed.count) deferred=\(report.deferred.count) failed=\(report.failed.count)")
        return !report.ranOut && report.failed.isEmpty
    }

    private func perform(_ step: Step, budget: BackgroundBudget) async throws {
        switch step {
        case .sync:
            await profileAccount.sync(.scheduled)
        case .cache:
            // Peers first: what they already fetched needn't be fetched again.
            if let cache { _ = await profileAccount.pullCache(into: cache) }
        case .subscriptions:
            await poller.poll(budget: budget)
        case .rekey:
            guard let cache else { return }
            while cache.needsMigration, budget.remaining > .seconds(2), !Task.isCancelled {
                cache.migrate(limit: 200, accounts: [])
                await Task.yield()
            }
        }
    }
}
