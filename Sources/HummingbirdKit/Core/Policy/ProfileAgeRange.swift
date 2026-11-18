import Foundation
import os
import Observation

/// What the profile knows about the user's age, as it syncs: an upper bound
/// on their birthday. A platform report "at least L years old" made on day D
/// proves the birthday is no later than D − L years. Nothing else is kept: no
/// birth date (even where the platform has one), no upper age, no raw
/// platform data. Only provenance: when the bound was measured and from what.
struct SyncedAgeRange: Codable, Hashable, Sendable {
    /// A calendar day, without a time or time zone.
    struct Day: Codable, Hashable, Sendable, Comparable {
        let year: Int, month: Int, day: Int
        static func < (a: Self, b: Self) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
    }

    /// The latest day the user can have been born, as a UTC calendar day.
    let latestPossibleBirthday: Day
    let measuredAt: Date
    /// What reported the age range (`platform`: the OS age signal;
    /// `correction`: someone lowered the profile's age by hand).
    let source: String
    /// The correction this record descends from: set to the moment of an
    /// explicit lowering, and carried by every later report. A newer
    /// correction outranks everything before it, so a lowering can win over
    /// tighter older bounds; within one correction, the tightest bound wins.
    let correctedAt: Date?

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// The bound a report of at least `lowerBound` years, made at
    /// `measuredAt`, proves. A measurement dated in the future (a skewed
    /// clock) counts as made now. 29 February minus L years lands on
    /// 28 February when that year has no 29th: the earlier day, so the bound
    /// never claims more age than the report proved.
    init(lowerBound: Int, measuredAt: Date, now: Date = Date(), source: String = "platform",
         correctedAt: Date? = nil) {
        let calendar = Self.utcCalendar()
        let day = min(measuredAt, now)
        let measured = calendar.dateComponents([.year, .month, .day], from: day)
        let shifted = calendar.date(byAdding: .year, value: -max(0, lowerBound), to: calendar.date(from: measured) ?? day) ?? day
        let bound = calendar.dateComponents([.year, .month, .day], from: shifted)
        latestPossibleBirthday = Day(year: bound.year ?? 0, month: bound.month ?? 1, day: bound.day ?? 1)
        self.measuredAt = day
        self.source = source
        self.correctedAt = correctedAt.map { min($0, now) }
    }

    /// The age the user has certainly reached on `date`: full years from the
    /// latest possible birthday. It rises on exactly the bound's anniversary;
    /// a 29 February bound has its anniversary on 1 March in other years.
    func minimumAge(on date: Date) -> Int {
        let today = Self.utcCalendar().dateComponents([.year, .month, .day], from: date)
        let (y0, m0, d0) = (latestPossibleBirthday.year, latestPossibleBirthday.month, latestPossibleBirthday.day)
        guard let y1 = today.year, let m1 = today.month, let d1 = today.day else { return 0 }
        return max(0, y1 - y0 - ((m1, d1) < (m0, d0) ? 1 : 0))
    }

    /// The record to keep of two. A total order: the newer correction
    /// first; then the tighter (earlier) bound, the earlier measurement and
    /// the source. Merging takes the first, so it is commutative and every
    /// device converges on the same record.
    static func preferred(_ a: Self, _ b: Self) -> Self {
        let epochA = a.correctedAt ?? .distantPast, epochB = b.correctedAt ?? .distantPast
        if epochA != epochB { return epochA > epochB ? a : b }
        func key(_ r: Self) -> (Day, Date, String) { (r.latestPossibleBirthday, r.measuredAt, r.source) }
        return key(a) <= key(b) ? a : b
    }
}

/// The profile's age range: profile data, synced. Platform reports only
/// ever raise it: each age-dependent decision asks the platform, turns a
/// shared range into a birthday bound and merges it (min), so the profile
/// keeps the tightest bound any instance has seen. Declined and unavailable
/// reports never write. Lowering it only restricts, so anyone may do it
/// after a confirmation (`lower(toMinimumAge:)`): that writes a correction,
/// which outranks earlier reports.
@MainActor
@Observable
final class ProfileAgeRange {
    private(set) var record: SyncedAgeRange?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loading: Task<SyncedAgeRange?, Never>?
    private let storage: Storage
    private let storageName: String
    @ObservationIgnored private let profileChanges: ProfileChangeStore?
    /// Called after the record changes, so sources are decided again.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(storage: Storage, storageName: String, profileChanges: ProfileChangeStore?) {
        self.storage = storage
        self.storageName = storageName
        self.profileChanges = profileChanges
    }

    /// The stored record, read from storage off the main actor once.
    func current() async -> SyncedAgeRange? {
        if loaded { return record }
        let task = loading ?? Task.detached(priority: .userInitiated) { [storage, storageName] in
            storage.load(SyncedAgeRange.self, name: storageName)
        }
        loading = task
        let stored = await task.value
        loading = nil
        if !loaded {
            record = Self.merged(record, stored)
            loaded = true
        }
        return record
    }

    /// Records a platform report of at least `lowerBound` years made now. It
    /// belongs to the current correction, so it can only tighten.
    func record(lowerBound: Int, now: Date = Date()) async {
        let current = await current()
        await merge(SyncedAgeRange(lowerBound: lowerBound, measuredAt: now, now: now,
                                   correctedAt: current?.correctedAt), announce: true)
    }

    /// Lowers the profile's minimum age to `age` (moves the birthday bound
    /// later). This only restricts, so it needs no passcode, just the
    /// user's confirmation in the UI. It syncs as a correction that outranks
    /// earlier reports; a later platform report can raise it again.
    func lower(toMinimumAge age: Int, now: Date = Date()) async {
        guard let current = await current(), age < current.minimumAge(on: now) else { return }
        let correction = SyncedAgeRange(lowerBound: age, measuredAt: now, now: now, source: "correction",
                                        correctedAt: now)
        Logger.policy.notice("age_bound_lowered_by_user")
        await merge(correction, announce: true)
    }

    /// A record from another instance of this profile. A looser one changes
    /// nothing, and the local record is written back so the journal
    /// converges on the tightest bound too. A record measured more than a
    /// day in the future (a badly skewed clock) is ignored.
    func applyRemote(_ remote: SyncedAgeRange, now: Date = Date()) async {
        let tolerance = now.addingTimeInterval(86_400)
        guard remote.measuredAt <= tolerance, (remote.correctedAt ?? .distantPast) <= tolerance else {
            Logger.policy.notice("age_range_ignored_future_measurement")
            return
        }
        let current = await current()
        guard remote != current else { return }
        if Self.merged(current, remote) == remote {
            await merge(remote, announce: false)
        } else if let current {
            profileChanges?.put(.ageRange(current))
        }
    }

    /// A delete from another instance cannot remove the bound: restate it.
    func applyRemoteDelete() async {
        if let current = await current() { profileChanges?.put(.ageRange(current)) }
    }

    nonisolated static func merged(_ a: SyncedAgeRange?, _ b: SyncedAgeRange?) -> SyncedAgeRange? {
        switch (a, b) {
        case let (a?, b?): return SyncedAgeRange.preferred(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private func merge(_ candidate: SyncedAgeRange, announce: Bool) async {
        let current = await current()
        let winner = Self.merged(current, candidate)
        guard winner == candidate, candidate != current else { return }
        record = candidate
        storage.save(candidate, name: storageName)
        if announce { profileChanges?.put(.ageRange(candidate)) }
        onChange?()
    }
}
