import Foundation
import Observation
import SwiftOpenUI
import ATProtoKit

/// A parent's approval of one source, given through the system's
/// parent-approval flow (PermissionKit on Apple platforms). Profile data:
/// synced, so the approval holds on every device of the profile.
struct SyncedParentalApproval: Codable, Hashable, Sendable {
    let pluginID: String
    let approvedAt: Date
}

/// A question sent to a parent and not answered yet. Kept on this device
/// only: the answer comes back to the device that asked.
struct PendingParentRequest: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let pluginID: String
    let name: String
    let sourceURL: String
    let askedAt: Date
}

/// Parents' approvals for this profile, and the questions still waiting for
/// an answer. There is no app passcode: approvals only come from the
/// system's answer to a question this app asked.
@MainActor
@Observable
final class ParentalApprovals {
    private struct Stored: Codable, Sendable {
        var approved: [SyncedParentalApproval] = []
        var pending: [PendingParentRequest] = []
    }

    private(set) var approved: [String: SyncedParentalApproval] = [:]
    private(set) var pending: [PendingParentRequest] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loading: Task<Stored?, Never>?
    private let storage: Storage
    private let storageName: String
    @ObservationIgnored private let profileChanges: ProfileChangeStore?
    /// Called when approvals change, so refused sources are retried.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    /// Called with a request a parent just approved, so its source installs.
    @ObservationIgnored var onApproved: [@MainActor (PendingParentRequest) -> Void] = []

    init(storage: Storage, storageName: String, profileChanges: ProfileChangeStore?) {
        self.storage = storage
        self.storageName = storageName
        self.profileChanges = profileChanges
    }

    /// Approvals of a rated setting are keyed "<plugin id>#<setting>".
    nonisolated static func settingKeyPrefix(_ pluginID: String) -> String { pluginID + "#" }
    nonisolated static func settingKey(_ pluginID: String, _ setting: String) -> String {
        settingKeyPrefix(pluginID) + setting
    }

    /// The approved plugin ids (and plugin#setting keys), read from storage
    /// off the main actor once.
    func current() async -> Set<String> {
        await load()
        return Set(approved.keys)
    }

    func recordRequest(id: UUID, pluginID: String, name: String, sourceURL: String, now: Date = Date()) async {
        await load()
        pending.removeAll { $0.pluginID == pluginID }
        pending.append(PendingParentRequest(id: id, pluginID: pluginID, name: name, sourceURL: sourceURL, askedAt: now))
        save()
    }

    /// The system delivered a parent's answer.
    func resolve(_ response: SystemParentalControls.ParentResponse, now: Date = Date()) async {
        await load()
        guard let request = pending.first(where: { $0.id == response.requestID }) else { return }
        pending.removeAll { $0.id == response.requestID }
        if response.approved {
            let approval = SyncedParentalApproval(pluginID: request.pluginID, approvedAt: now)
            approved[request.pluginID] = approval
            profileChanges?.put(.parentalApproval(approval))
            save()
            onChange?()
            onApproved.forEach { $0(request) }
        } else {
            save()
        }
    }

    /// An approval from another instance of this profile.
    func applyRemote(_ approval: SyncedParentalApproval) async {
        await load()
        guard approved[approval.pluginID] != approval else { return }
        approved[approval.pluginID] = approval
        save()
        onChange?()
    }

    /// Withdrawing an approval only restricts, so any instance may do it.
    func applyRemoteDelete(key: RecordKey) async {
        await load()
        guard let id = approved.keys.first(where: { HummingbirdProfileSchema.key(for: $0) == key }) else { return }
        approved[id] = nil
        save()
        onChange?()
    }

    /// Withdraws an approval here and on the profile's other devices.
    func withdraw(_ pluginID: String) async {
        await load()
        guard approved.removeValue(forKey: pluginID) != nil else { return }
        profileChanges?.delete(collection: HummingbirdProfileSchema.parentalApproval,
                               key: HummingbirdProfileSchema.key(for: pluginID))
        save()
        onChange?()
    }

    var syncedRecords: [SyncedParentalApproval] { Array(approved.values) }

    private func load() async {
        if loaded { return }
        let task = loading ?? Task.detached(priority: .userInitiated) { [storage, storageName] in
            storage.load(Stored.self, name: storageName)
        }
        loading = task
        let stored = await task.value
        loading = nil
        guard !loaded else { return }
        loaded = true
        for approval in stored?.approved ?? [] where approved[approval.pluginID] == nil {
            approved[approval.pluginID] = approval
        }
        pending = (stored?.pending ?? []) + pending.filter { request in
            !(stored?.pending ?? []).contains { $0.id == request.id }
        }
    }

    private func save() {
        storage.save(Stored(approved: Array(approved.values), pending: pending), name: storageName)
    }
}
