import Crypto
import Foundation
import os
#if canImport(FoundationXML)
import FoundationXML
#endif
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
    private let localNetworkStatus: () -> PermissionStatus?

    /// `localNetworkStatus` reports the system's stored decision when it can be
    /// read without touching the network, or nil when it can't.
    init(localNetworkStatus: @escaping () -> PermissionStatus? = PlatformPermissions.recordedLocalNetworkStatus) {
        self.localNetworkStatus = localNetworkStatus
    }

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
            // No public API reports this, and probing the network would itself
            // prompt. Where the system's stored decision is readable, use it.
            return localNetworkStatus() ?? .unreported
        case .camera:
            // The system reports camera authorization itself, however it keys
            // it, so no record of ours is involved.
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

    /// The local network decision macOS has stored for this app, read from
    /// its world-readable rule file. Nil elsewhere, or when nothing is stored.
    nonisolated static func recordedLocalNetworkStatus() -> PermissionStatus? {
        #if os(macOS)
        guard let data = try? Data(contentsOf: LocalNetworkPrivacyRules.systemFile) else { return nil }
        return LocalNetworkPrivacyRules.status(for: AppSigningIdentity.current(), in: data)
        #else
        return nil
        #endif
    }
}

/// What the system's privacy controls know this app as.
///
/// macOS stores each local network decision as a rule matched by the app's
/// code-signing identifier alone: the rules in
/// /Library/Preferences/com.apple.networkextension.plist carry a
/// `SigningIdentifier`, no designated requirement, and
/// `AllowEmptyDesignatedRequirement`. A rebuilt or re-signed app with the same
/// identifier keeps its grant; a different bundle identifier starts over.
///
/// Both answers are fixed for the life of the process, so each is worked out
/// once. The code-signing calls behind them must not run on the main thread
/// (Security reports them as a runtime issue there); `prepare()` runs them
/// during launch, off the main thread, before anything asks.
enum AppSigningIdentity {
    static func current() -> String { currentIdentity }

    /// What earlier builds keyed their record by: the designated requirement
    /// on macOS, the bundle identifier elsewhere.
    static func legacyKey() -> String { legacyIdentity }

    /// Works both answers out now. Call it off the main thread.
    static func prepare() {
        _ = currentIdentity
        _ = legacyIdentity
    }

    private static let currentIdentity: String = {
        #if os(macOS)
        if let identifier = signingIdentifier() { return identifier }
        #endif
        return Bundle.main.bundleIdentifier ?? Bundle.main.bundleURL.path
    }()

    private static let legacyIdentity: String = {
        #if os(macOS)
        if let requirement = designatedRequirement() { return requirement }
        return Bundle.main.bundleURL.path
        #else
        return Bundle.main.bundleIdentifier ?? "app"
        #endif
    }()

    #if os(macOS)
    private static func staticSelf() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func signingIdentifier() -> String? {
        guard let staticCode = staticSelf() else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoIdentifier as String] as? String
    }

    private static func designatedRequirement() -> String? {
        guard let staticCode = staticSelf() else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
    #endif
}

/// Reads macOS's stored local network decisions without touching the network.
///
/// The file is an undocumented keyed archive, so anything unexpected yields
/// nil and the caller falls back to its own record. A rule counts only once
/// the user has answered (`MulticastPreferenceSet`); `DenyMulticast` is then
/// the answer.
///
/// Identifiers match without regard to case, as the system's do: a build
/// signed `com.eightybps.hummingbird` was not prompted again after the user
/// had allowed `com.eightybps.Hummingbird`.
enum LocalNetworkPrivacyRules {
    static let systemFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.networkextension.plist")

    static func status(for signingIdentifier: String, in data: Data) -> PermissionStatus? {
        guard let objects = archivedObjects(data) else { return nil }
        let references = Set(objects.indices.filter {
            guard case .string(let value) = objects[$0] else { return false }
            return value.caseInsensitiveCompare(signingIdentifier) == .orderedSame
        }.map { PlistNode.dictionary(["CF$UID": .integer($0)]) })
        guard !references.isEmpty else { return nil }
        var decision: PermissionStatus?
        for case .dictionary(let rule) in objects {
            guard let identifier = rule["SigningIdentifier"], references.contains(identifier) else { continue }
            guard rule["MulticastPreferenceSet"] == .bool(true),
                  case .bool(let denied) = rule["DenyMulticast"] else { continue }
            if denied { return .denied }
            decision = .granted
        }
        return decision
    }

    /// The archive's `$objects`, with object references left as `CF$UID`
    /// dictionaries, which is how they appear in XML form.
    private static func archivedObjects(_ data: Data) -> [PlistNode]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              case .dictionary(let root) = PlistXMLReader.parse(xml),
              case .array(let objects) = root["$objects"] else { return nil }
        return objects
    }
}

enum PlistNode: Hashable {
    case dictionary([String: PlistNode])
    case array([PlistNode])
    case string(String)
    case integer(Int)
    case bool(Bool)
    case other
}

/// A minimal reader for XML property lists that keeps `CF$UID` references as
/// plain dictionaries (PropertyListSerialization turns them back into opaque
/// archiver UIDs).
private final class PlistXMLReader: NSObject, XMLParserDelegate {
    private enum Frame {
        case dictionary([String: PlistNode], pendingKey: String?)
        case array([PlistNode])
    }

    private var stack: [Frame] = []
    private var text = ""
    private var result: PlistNode?

    static func parse(_ data: Data) -> PlistNode? {
        let reader = PlistXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return reader.result
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "dict": stack.append(.dictionary([:], pendingKey: nil))
        case "array": stack.append(.array([]))
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        defer { text = "" }
        switch element {
        case "plist":
            break
        case "key":
            if case .dictionary(let values, _) = stack.last {
                stack[stack.count - 1] = .dictionary(values, pendingKey: text)
            }
        case "dict":
            if case .dictionary(let values, _) = stack.popLast() { add(.dictionary(values)) }
        case "array":
            if case .array(let values) = stack.popLast() { add(.array(values)) }
        case "string": add(.string(text))
        case "integer": add(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(PlistNode.integer) ?? .other)
        case "true": add(.bool(true))
        case "false": add(.bool(false))
        default: add(.other)
        }
    }

    private func add(_ node: PlistNode) {
        switch stack.last {
        case .dictionary(var values, let key?):
            values[key] = node
            stack[stack.count - 1] = .dictionary(values, pendingKey: nil)
        case .array(var values):
            values.append(node)
            stack[stack.count - 1] = .array(values)
        case .dictionary(_, nil):
            break
        case nil:
            result = node
        }
    }
}

/// Keeps this instance's permission record in a small file of its own.
///
/// "This instance" is what the system authorizes: the code-signing identifier
/// (see `AppSigningIdentity`). Builds that share it share the system's
/// decision and so share this record; builds with other identifiers keep
/// their own. iOS-family records are excluded from backups because restored
/// devices prompt again.
///
/// Earlier builds keyed records by a hash of the designated requirement. Their
/// recorded uses still count: on first open, uses from every earlier record
/// are carried over, and so are declines from the one this build wrote.
@MainActor
final class FilePermissionLedger: PermissionLedger {
    private struct Record: Codable {
        var used: Set<ProtectedResource> = []
        var declined: Set<String> = []
        var migratedLegacyRecords = false

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            used = try container.decodeIfPresent(Set<ProtectedResource>.self, forKey: .used) ?? []
            declined = try container.decodeIfPresent(Set<String>.self, forKey: .declined) ?? []
            migratedLegacyRecords = try container.decodeIfPresent(Bool.self, forKey: .migratedLegacyRecords) ?? false
        }
    }

    private let fileURL: URL
    private var record: Record

    init(directory: URL,
         instance: String = AppSigningIdentity.current(),
         legacyInstance: String = AppSigningIdentity.legacyKey()) {
        // Lowercased: the system treats identifiers differing only in case as one app.
        fileURL = directory.appendingPathComponent("app-\(Self.fileSafe(instance.lowercased())).json")
        record = Self.load(fileURL) ?? Record()
        if !record.migratedLegacyRecords {
            migrateLegacyRecords(in: directory, ownLegacyName: "\(Self.legacyDigest(legacyInstance)).json")
        }
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

    private func migrateLegacyRecords(in directory: URL, ownLegacyName: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard names.contains(where: Self.isLegacyName) else { return }
        for name in names where Self.isLegacyName(name) {
            guard let legacy = Self.load(directory.appendingPathComponent(name)) else { continue }
            // A use under any earlier key means the system has already asked a
            // Hummingbird build; declines were choices about that build only.
            record.used.formUnion(legacy.used)
            if name == ownLegacyName { record.declined.formUnion(legacy.declined) }
        }
        record.migratedLegacyRecords = true
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
            Logger.permissions.error("record_save_failed error=\(String(reflecting: type(of: error)), privacy: .public) message=\(error.localizedDescription)")
        }
    }

    private static func load(_ url: URL) -> Record? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    /// The file name stem earlier builds used for `instance`.
    static func legacyDigest(_ instance: String) -> String {
        SHA256.hash(data: Data(instance.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLegacyName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return stem.count == 24 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func fileSafe(_ instance: String) -> String {
        String(instance.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
    }
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
