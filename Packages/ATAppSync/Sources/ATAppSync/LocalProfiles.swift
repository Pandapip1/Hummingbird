import Foundation

public struct AppSyncLocalProfile: Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let peerService: AppSyncPeerService
}

/// Durable collection of independent local profiles. Each profile receives its
/// own instance keys, inbox, trust graph, and instance ID. Applications choose
/// which profile's data to materialize while every loaded profile may remain
/// discoverable and reachable on the LAN.
public final class AppSyncProfileRegistry: @unchecked Sendable {
    private struct Descriptor: Codable {
        let id: UUID
        let createdAt: Date
    }
    private struct Snapshot: Codable { var profiles: [Descriptor] }

    private let credentialStore: any AppSyncCredentialStore
    private let storageDirectory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var descriptors: [UUID: Descriptor]
    private var loaded: [UUID: AppSyncPeerService] = [:]

    public init(credentialStore: any AppSyncCredentialStore, storageDirectory: URL) throws {
        self.credentialStore = credentialStore
        self.storageDirectory = storageDirectory
        fileURL = storageDirectory.appendingPathComponent(
            "profiles", isDirectory: true
        ).appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: fileURL) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            descriptors = Dictionary(uniqueKeysWithValues: snapshot.profiles.map { ($0.id, $0) })
        } else {
            descriptors = [:]
        }
    }

    public func profiles() throws -> [AppSyncLocalProfile] {
        try lock.withLock {
            try descriptors.values.sorted { $0.createdAt < $1.createdAt }.map(load)
        }
    }

    public func createProfile() throws -> AppSyncLocalProfile {
        try ensureProfile(id: UUID())
    }

    public func ensureProfile(id: UUID, migrateLegacyIdentity: Bool = false) throws
        -> AppSyncLocalProfile {
        try lock.withLock {
            if let descriptor = descriptors[id] { return try load(descriptor) }
            let descriptor = Descriptor(id: id, createdAt: Date())
            var next = descriptors
            next[id] = descriptor
            try persist(next)
            descriptors = next
            let service = try AppSyncPeerService(
                credentialStore: credentialStore, storageDirectory: storageDirectory,
                profileID: id, migrateLegacyIdentity: migrateLegacyIdentity
            )
            loaded[id] = service
            return .init(id: id, createdAt: descriptor.createdAt, peerService: service)
        }
    }

    /// Keeps every profile visible concurrently. A profile gets its own DNS-SD
    /// service instance and signed registration, all using the common service type.
    public func exposeAll(appIDs: Set<AppSyncAppID>) async {
        guard let profiles = try? profiles() else { return }
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask {
                    _ = try? await profile.peerService.startLANServer(appIDs: appIDs)
                }
            }
        }
    }

    private func load(_ descriptor: Descriptor) throws -> AppSyncLocalProfile {
        if let service = loaded[descriptor.id] {
            return .init(id: descriptor.id, createdAt: descriptor.createdAt, peerService: service)
        }
        let service = try AppSyncPeerService(
            credentialStore: credentialStore, storageDirectory: storageDirectory,
            profileID: descriptor.id
        )
        loaded[descriptor.id] = service
        return .init(id: descriptor.id, createdAt: descriptor.createdAt, peerService: service)
    }

    private func persist(_ value: [UUID: Descriptor]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let profiles = value.values.sorted { $0.createdAt < $1.createdAt }
        try JSONEncoder().encode(Snapshot(profiles: profiles)).write(to: fileURL, options: .atomic)
    }
}
