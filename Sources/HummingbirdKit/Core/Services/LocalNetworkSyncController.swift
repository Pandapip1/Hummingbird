import ATAppSync
import Foundation
import Observation

/// Runs Local Network Sync on this instance: the shared setting, whether it is
/// actually running here, and the permission gate in between.
///
/// The setting is shared with other instances (they read the same preference),
/// so it can be on here without anyone having turned it on here. Starting
/// DNS-SD makes the system ask for local network access, so a setting that is
/// merely restored or synced goes through `PermissionGate` with
/// `.settings` origin and the user sees why before the system prompt.
///
/// "Off on this device" is kept apart from the shared setting: declining stops
/// sync on this instance only and leaves the shared setting, and with it every
/// other instance, alone. The decline holds while the shared setting stays on;
/// once this instance sees it off, the decline is forgotten so a later "on"
/// asks again. Turning the toggle on here always clears it.
@MainActor
@Observable
final class LocalNetworkSyncController {
    enum State: Equatable {
        case disabled
        /// The explanation is showing; nothing has touched the network yet.
        case awaitingPermission
        /// The user chose "Not Now"; asked again next launch or on request.
        case postponed
        /// The shared setting is on, but the user turned it off here.
        case offOnThisDevice
        case starting
        case available
        /// Local network privacy blocks Hummingbird; only the user can
        /// change that, in the system's privacy settings.
        case blockedBySystem
        case failed(String)
    }

    /// Starts and stops the DNS-SD advertisement and LAN listeners.
    struct Transport {
        var expose: @MainActor () async throws -> Void
        var conceal: @MainActor () -> Void
        /// Fires when local network privacy blocks the exposed transport
        /// after `expose` returned (how iOS reports "Don't Allow").
        var denials: @MainActor () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    }

    static let feature = "local-network-sync"

    /// The shared setting.
    private(set) var isEnabled: Bool
    private(set) var state: State

    /// What the toggle shows: the shared setting, unless declined or blocked
    /// here. A toggle that reads "on" must mean sync can run.
    var isOnHere: Bool { isEnabled && state != .offOnThisDevice && state != .blockedBySystem }
    /// Whether this instance may use the local network for sync right now.
    var isActive: Bool { state == .starting || state == .available }

    @ObservationIgnored private let gate: PermissionGate
    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private let persist: (Bool) -> Void
    @ObservationIgnored private let activeChanged: @MainActor (Bool) -> Void
    @ObservationIgnored private var generation = 0

    init(isEnabled: Bool, gate: PermissionGate, transport: Transport,
         persist: @escaping (Bool) -> Void,
         activeChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.isEnabled = isEnabled
        self.gate = gate
        self.transport = transport
        self.persist = persist
        self.activeChanged = activeChanged
        state = .disabled
    }

    /// Applies the setting found at launch, which may have been turned on by
    /// another instance. No user action here asked for it, so the gate
    /// explains first.
    func applyStoredSetting() async {
        guard isEnabled else {
            gate.forgetDecline(of: Self.feature)
            return
        }
        await start(origin: .settings)
    }

    /// The user flipped the toggle on this instance.
    func setEnabled(_ enabled: Bool) async {
        if enabled {
            if !isEnabled { isEnabled = true; persist(true) }
            await start(origin: .userAction)
        } else {
            guard isEnabled else { return }
            isEnabled = false
            persist(false)
            stop()
            gate.forgetDecline(of: Self.feature)
        }
    }

    /// The user asked to start again after a failure or "Not Now".
    func retry() async {
        guard isEnabled else { return }
        await start(origin: .userAction)
    }

    private func start(origin: PermissionOrigin) async {
        generation += 1
        let attempt = generation
        if !isActive { state = origin == .settings ? .awaitingPermission : .starting }
        let decision = await gate.authorize(
            .localNetwork, for: Self.feature, origin: origin, explanation: .localNetworkSync
        )
        guard attempt == generation, isEnabled else { return }
        switch decision {
        case .allowed:
            break
        case .notNow:
            stop(); state = .postponed; return
        case .declinedOnThisDevice:
            stop(); state = .offOnThisDevice; return
        case .deniedBySystem:
            stop(); state = .blockedBySystem; return
        }
        guard state != .available else { return }
        state = .starting
        do {
            try await transport.expose()
            gate.recordUse(of: .localNetwork)
            guard attempt == generation, isEnabled else {
                // Stopped while starting: don't leave it advertising.
                if !isActive { transport.conceal() }
                return
            }
            state = .available
            activeChanged(true)
            watchForDenial(attempt)
        } catch {
            if case InstanceMessagingError.localNetworkDiscoveryFailed = error {
                gate.recordUse(of: .localNetwork)
            }
            transport.conceal()
            guard attempt == generation, isEnabled else { return }
            if case let InstanceMessagingError.localNetworkDiscoveryFailed(_, code) = error,
               code == InstanceMessagingError.dnsServicePolicyDenied {
                state = .blockedBySystem
            } else {
                state = .failed(error.localizedDescription)
            }
            activeChanged(false)
        }
    }

    /// A denial can arrive after starting succeeded; stop then rather than
    /// showing sync as running.
    private func watchForDenial(_ attempt: Int) {
        let denials = transport.denials()
        Task { [weak self] in
            for await _ in denials {
                guard let self, attempt == self.generation else { return }
                let wasActive = self.isActive
                self.transport.conceal()
                self.state = .blockedBySystem
                if wasActive { self.activeChanged(false) }
                return
            }
        }
    }

    private func stop() {
        generation += 1
        let wasActive = isActive
        transport.conceal()
        state = .disabled
        if wasActive { activeChanged(false) }
    }
}
