import Crypto
import Foundation
#if os(iOS) || os(macOS)
import AVFoundation
#endif
#if os(macOS)
import Security
#endif

/// The running platform's permission prompts. Apple platforms prompt for local
/// network and camera access; Linux never prompts, so the gate passes straight
/// through there. This follows the OS, not the UI backend: a GTK build on macOS
/// is still subject to macOS's local network privacy.
@MainActor
final class PlatformPermissions: SystemPermissions {
    var presentsPrompts: Bool {
        #if canImport(Darwin)
        true
        #else
        false
        #endif
    }

    func status(of resource: ProtectedResource) -> PermissionStatus {
        switch resource {
        case .localNetwork:
            return .unreported
        case .camera:
            #if os(iOS) || os(macOS)
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .notDetermined: return .undetermined
            case .denied, .restricted: return .denied
            @unknown default: return .undetermined
            }
            #else
            return presentsPrompts ? .denied : .granted
            #endif
        }
    }

    func request(_ resource: ProtectedResource) async -> Bool {
        switch resource {
        case .localNetwork:
            return true
        case .camera:
            #if os(iOS) || os(macOS)
            return await AVCaptureDevice.requestAccess(for: .video)
            #else
            return !presentsPrompts
            #endif
        }
    }
}

/// Keeps this instance's permission record in a small file of its own.
///
/// "This instance" is what the system authorizes: on macOS, the app's code
/// signature (its designated requirement), so an Xcode build and an xtool
/// build sharing one preferences domain still keep separate records, as the
/// system keeps separate authorizations. iOS-family apps are one instance per
/// install; their record is excluded from backups because restored devices
/// prompt again.
@MainActor
final class FilePermissionLedger: PermissionLedger {
    private struct Record: Codable {
        var used: Set<ProtectedResource> = []
        var declined: Set<String> = []
    }

    private let fileURL: URL
    private var record: Record

    init(directory: URL = Storage.directory.appendingPathComponent("permissions", isDirectory: true),
         instance: String = FilePermissionLedger.currentInstance()) {
        let digest = SHA256.hash(data: Data(instance.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        fileURL = directory.appendingPathComponent("\(digest).json")
        record = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    func hasUsed(_ resource: ProtectedResource) -> Bool { record.used.contains(resource) }

    func recordUse(of resource: ProtectedResource) {
        record.used.insert(resource)
        save()
    }

    func isDeclined(_ feature: String) -> Bool { record.declined.contains(feature) }

    func setDeclined(_ feature: String, _ declined: Bool) {
        guard declined != record.declined.contains(feature) else { return }
        if declined { record.declined.insert(feature) } else { record.declined.remove(feature) }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
            #if os(iOS) || os(tvOS) || os(visionOS)
            var url = fileURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            #endif
        } catch {
            // Losing the record costs one extra explanation, never a silent prompt.
            print("Couldn't save the permission record: \(error.localizedDescription)")
        }
    }

    /// Identifies the running app as the system's privacy controls see it.
    nonisolated static func currentInstance() -> String {
        #if os(macOS)
        if let requirement = designatedRequirement() { return requirement }
        return Bundle.main.bundleURL.path
        #else
        return Bundle.main.bundleIdentifier ?? "app"
        #endif
    }

    #if os(macOS)
    private nonisolated static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
    #endif
}

/// A ledger that lives only in memory, for previews and tests.
@MainActor
final class InMemoryPermissionLedger: PermissionLedger {
    private(set) var used: Set<ProtectedResource>
    private(set) var declined: Set<String>

    init(used: Set<ProtectedResource> = [], declined: Set<String> = []) {
        self.used = used
        self.declined = declined
    }

    func hasUsed(_ resource: ProtectedResource) -> Bool { used.contains(resource) }
    func recordUse(of resource: ProtectedResource) { used.insert(resource) }
    func isDeclined(_ feature: String) -> Bool { declined.contains(feature) }
    func setDeclined(_ feature: String, _ value: Bool) {
        if value { declined.insert(feature) } else { declined.remove(feature) }
    }
}
