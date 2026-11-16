import Foundation
import Observation

/// Something the operating system guards behind a one-time permission prompt.
enum ProtectedResource: String, Codable, Sendable, CaseIterable {
    /// Bonjour/DNS-SD and connections to hosts on the local network.
    case localNetwork
    case camera
}

/// Why a feature is about to use a protected resource.
enum PermissionOrigin: Sendable, Equatable {
    /// The user just acted on this instance (flipped the toggle, tapped the
    /// button) to use the feature. The system prompt follows as an answer to
    /// that action, so it is shown straight away.
    case userAction
    /// Nothing the user did here asked for it: the setting was restored at
    /// launch, arrived from another instance, or is applied in the background.
    /// The user first sees an in-app explanation and decides whether to go on.
    case settings
}

/// What the platform reports about a resource's authorization.
enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case undetermined
    /// The platform offers no status API (local network privacy): whether a
    /// prompt is still to come is known only from this instance's own record.
    case unreported
}

/// The in-app modal shown before a settings-driven system prompt.
struct PermissionExplanation: Sendable, Equatable {
    var title: String
    var message: String
    var continueTitle = "Continue"
    var declineTitle = "Turn Off on This Device"
    var deferTitle = "Not Now"
}

/// The outcome of asking the gate.
enum PermissionDecision: Sendable, Equatable {
    /// Use the protected API.
    case allowed
    /// The user postponed. Nothing is remembered beyond this launch.
    case notNow
    /// The user turned the feature off on this instance. Remembered until they
    /// turn it on here again.
    case declinedOnThisDevice
    /// The system refuses; only the system's settings can change that.
    case deniedBySystem
}

/// The user's answer to the in-app modal.
enum PermissionChoice: Sendable, Equatable {
    case `continue`
    case notNow
    case offOnThisDevice
}

/// The platform's permission machinery.
@MainActor
protocol SystemPermissions: AnyObject {
    /// False where the platform never prompts (Linux), so the gate opens at once.
    var presentsPrompts: Bool { get }
    func status(of resource: ProtectedResource) -> PermissionStatus
    /// Shows the system prompt for resources that have a request API. Returns
    /// whether access is granted. For resources without one (local network),
    /// returns true: the caller's first use of the API is what prompts.
    func request(_ resource: ProtectedResource) async -> Bool
}

/// What this instance remembers about permissions. Never synced: another
/// instance has its own system authorization and its own user decisions.
@MainActor
protocol PermissionLedger: AnyObject {
    /// Whether this instance has already used the resource, so the system has
    /// had its one chance to prompt. Only consulted for `.unreported` status.
    func hasUsed(_ resource: ProtectedResource) -> Bool
    func recordUse(of resource: ProtectedResource)
    func isDeclined(_ feature: String) -> Bool
    func setDeclined(_ feature: String, _ declined: Bool)
}

/// Decides when a protected resource may be touched, and shows the in-app
/// explanation first when the request comes from settings rather than from
/// the user. Every feature that uses a protected resource goes through here.
@MainActor
@Observable
final class PermissionGate {
    struct Prompt: Identifiable, Equatable {
        let id = UUID()
        let resource: ProtectedResource
        let feature: String
        let explanation: PermissionExplanation
    }

    /// The modal to show now, if any. Answer it with `respond(_:)`.
    private(set) var prompt: Prompt?

    @ObservationIgnored private var queued: [Prompt] = []
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<PermissionChoice, Never>]] = [:]
    /// Features postponed with "Not Now"; asked again on the next launch.
    @ObservationIgnored private var postponed: Set<String> = []
    /// Resources the user agreed to have the system ask about this launch.
    @ObservationIgnored private var agreed: Set<ProtectedResource> = []
    @ObservationIgnored private let system: any SystemPermissions
    @ObservationIgnored private let ledger: any PermissionLedger

    init(system: any SystemPermissions, ledger: any PermissionLedger) {
        self.system = system
        self.ledger = ledger
    }

    /// Call before touching `resource` for `feature`. `feature` names what the
    /// user can decline (e.g. local sync, one plugin's LAN access) and keys the
    /// "off on this device" memory.
    func authorize(
        _ resource: ProtectedResource, for feature: String, origin: PermissionOrigin,
        explanation: @autoclosure () -> PermissionExplanation
    ) async -> PermissionDecision {
        guard system.presentsPrompts else { return .allowed }
        // The user's own choice for this feature comes first: a decline holds
        // even after the system has granted the resource to something else.
        switch origin {
        case .userAction:
            ledger.setDeclined(feature, false)
            postponed.remove(feature)
        case .settings:
            if ledger.isDeclined(feature) { return .declinedOnThisDevice }
            if postponed.contains(feature) { return .notNow }
        }
        switch system.status(of: resource) {
        case .granted: return .allowed
        case .denied: return .deniedBySystem
        case .unreported where ledger.hasUsed(resource): return .allowed
        case .undetermined, .unreported: break
        }
        switch origin {
        case .userAction:
            return await requestFromSystem(resource)
        case .settings:
            if agreed.contains(resource) { return await requestFromSystem(resource) }
            switch await ask(Prompt(resource: resource, feature: feature, explanation: explanation())) {
            case .continue:
                return await requestFromSystem(resource)
            case .notNow:
                postponed.insert(feature)
                return .notNow
            case .offOnThisDevice:
                ledger.setDeclined(feature, true)
                return .declinedOnThisDevice
            }
        }
    }

    /// Records that the protected API was touched, whatever it returned: the
    /// system has had its chance to prompt, so there is nothing left to explain.
    func recordUse(of resource: ProtectedResource) {
        guard system.presentsPrompts, !ledger.hasUsed(resource) else { return }
        ledger.recordUse(of: resource)
    }

    /// Forgets "off on this device" for a feature, e.g. once its shared
    /// setting is off so the decline no longer has anything to hold back.
    func forgetDecline(of feature: String) {
        if ledger.isDeclined(feature) { ledger.setDeclined(feature, false) }
        postponed.remove(feature)
    }

    /// Answers the modal currently shown.
    func respond(_ choice: PermissionChoice) {
        guard let current = prompt else { return }
        if choice == .continue { agreed.insert(current.resource) }
        resume(current.feature, with: choice)
        if choice == .continue {
            // One system prompt covers the resource, so other features waiting
            // on the same resource need no modal of their own.
            for other in queued where other.resource == current.resource {
                resume(other.feature, with: .continue)
            }
            queued.removeAll { $0.resource == current.resource }
        }
        prompt = nil
        guard !queued.isEmpty else { return }
        // Let the answered modal close before the next one is shown.
        Task { @MainActor [weak self] in
            guard let self, self.prompt == nil, !self.queued.isEmpty else { return }
            self.prompt = self.queued.removeFirst()
        }
    }

    private func ask(_ request: Prompt) async -> PermissionChoice {
        await withCheckedContinuation { continuation in
            let alreadyAsking = waiters[request.feature] != nil
            waiters[request.feature, default: []].append(continuation)
            guard !alreadyAsking else { return }
            if prompt == nil { prompt = request } else { queued.append(request) }
        }
    }

    private func resume(_ feature: String, with choice: PermissionChoice) {
        for waiter in waiters.removeValue(forKey: feature) ?? [] { waiter.resume(returning: choice) }
    }

    private func requestFromSystem(_ resource: ProtectedResource) async -> PermissionDecision {
        await system.request(resource) ? .allowed : .deniedBySystem
    }
}

/// Explanations shown before settings-driven use of a protected resource.
extension PermissionExplanation {
    /// The scanner opens only from a tap today, so this is a fallback for any
    /// path that opens it without one.
    static let qrScanner = PermissionExplanation(
        title: "Allow Camera Access?",
        message: "Hummingbird uses the camera only to scan QR codes for plugin sources and instance verification. Your system will ask next.",
        declineTitle: "Don’t Use the Camera Here"
    )

    static let localNetworkSync = PermissionExplanation(
        title: "Allow Local Network Access?",
        message: "Local Network Sync is on, from another Hummingbird instance or an earlier session. To find your other devices and sync with them directly, Hummingbird needs permission to use your local network. Your system will ask next."
    )

    /// Pairing starts from a tap or a scanned code, so this is a fallback for
    /// any path that starts it without one.
    static let credentialPairing = PermissionExplanation(
        title: "Allow Local Network Access?",
        message: "To pass a sign-in between this device and your other device directly, Hummingbird needs permission to use your local network. Your system will ask next.",
        declineTitle: "Don’t Pair on This Device"
    )

    static func pluginLocalNetwork(source: String, host: String) -> PermissionExplanation {
        PermissionExplanation(
            title: "Allow Local Network Access?",
            message: "“\(source)” loads from \(host), which is on your local network. To reach it, Hummingbird needs permission to use your local network. Your system will ask next.",
            declineTitle: "Block on This Device"
        )
    }
}
