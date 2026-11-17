import ATAppSync
import Foundation
import QRCodeGenerator
import SwiftOpenUI

@MainActor
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var peers: [AppSyncPeerTrustSummary] = []
    @State private var isLoading = false
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var peerToDistrust: AppSyncPeerTrustSummary?
    @State private var showingLocalCode = false
    @State private var accountIdentifier = ""
    @State private var enteringCode = false
    @State private var enteredCode = ""

    var body: some View {
        Group {
            if isScanning {
                QRCodeScanner(instruction: "Scan the other instance's peer code") { value in
                    isScanning = false
                    Task { await verify(value) }
                }
            } else {
                List {
                    Section {
                        Toggle(
                            "Local Network Sync",
                            isOn: Binding(
                                get: { app.localNetworkSync.isOnHere },
                                // A flip of the toggle is a direct request, so
                                // the system may prompt straight away.
                                set: { enabled in Task { await app.localNetworkSync.setEnabled(enabled) } }
                            )
                        )
                        switch app.localNetworkSync.state {
                        case .disabled:
                            EmptyView()
                        case .awaitingPermission:
                            Label("Waiting for you to allow local network access", systemImage: "hand.raised")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .postponed:
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Paused on this device until local network access is allowed", systemImage: "pause.circle")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("Allow and Start") { Task { await app.localNetworkSync.retry() } }
                            }
                        case .offOnThisDevice:
                            Label("Turned off on this instance. Turn it on here to sync from this instance too.", systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .starting:
                            ProgressView("Starting local sync…")
                        case .available:
                            Label("Available to trusted instances nearby", systemImage: "checkmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        case .blockedBySystem:
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Local network access is off for Hummingbird", systemImage: "hand.raised.slash")
                                    .foregroundStyle(.orange)
                                Text("Allow local network access for Hummingbird in \(PrivacySettings.location(of: .localNetwork)), then turn Local Network Sync on again.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if PrivacySettings.canOpen(.localNetwork) {
                                    Button("Open Settings") { PrivacySettings.open(.localNetwork) }
                                }
                            }
                        case .failed(let message):
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Local sync is unavailable", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                                Button("Try Again") { Task { await app.localNetworkSync.retry() } }
                            }
                        }
                    } footer: {
                        Text("When enabled, Hummingbird asks for local-network access, advertises this profile with DNS-SD, and exchanges encrypted sync data directly with trusted instances nearby. Your instance identity and offline changes remain stored when this is off.")
                    }
                    Section("AT Protocol Account") {
                        accountControls
                    }
                    Section("This instance") {
                        if let service = app.peerService {
                            PeerIdentityLabel(peerID: service.peer.publicIdentity.stableID)
                            Button("Show Verification Code") { showingLocalCode = true }
                        } else {
                            Text(app.peerServiceFailure.map { "Local peer identity is unavailable: \($0)" }
                                 ?? "Local peer identity is unavailable.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Instances") {
                        if isLoading && peers.isEmpty {
                            ProgressView("Finding instances…")
                        } else if peers.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No other instances").font(.headline)
                                Text(emptyDescription).font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(peers) { peer in
                                PeerTrustRow(
                                    peer: peer,
                                    compareEmoji: { Task { await compareEmoji(with: peer) } },
                                    scan: { isScanning = true },
                                    enterCode: { enteringCode = true },
                                    distrust: { peerToDistrust = peer }
                                )
                            }
                        }
                    }

                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
                    }
                }
            }
        }
        .navigationTitle("Sync")
        // Verifications, including ones another instance starts, are shown
        // only here, not over every page.
        .peerVerificationPrompts(app.profileAccount)
        .toolbar {
            // Verifying starts from the instance's own row ("Verify Directly").
            if isScanning {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isScanning = false }
                }
            }
        }
        .task {
            await reload()
            // Instances come and go and trust changes from other devices;
            // keep the list current while it is on screen.
            for await _ in app.profileAccount.peerChanges() { await reload() }
        }
        .alert("Enter Verification Code", isPresented: $enteringCode) {
            TextField("Code", text: $enteredCode)
                .autocorrectionDisabled()
            Button("Verify") {
                let code = enteredCode.trimmingCharacters(in: .whitespacesAndNewlines)
                enteredCode = ""
                Task { await verify(code) }
            }
            Button("Cancel", role: .cancel) { enteredCode = "" }
        } message: {
            Text("On the other instance, open Sync › Show Verification Code and copy the code under the QR code.")
        }
        .sheet(isPresented: $showingLocalCode) {
            if let service = app.peerService {
                PeerVerificationCodeSheet(code: service.verificationCode)
                    .sheetSize()
            }
        }
        .confirmationDialog(
            "Distrust this instance?",
            isPresented: Binding(
                get: { peerToDistrust != nil },
                set: { if !$0 { peerToDistrust = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Distrust Instance", role: .destructive) {
                guard let peer = peerToDistrust else { return }
                peerToDistrust = nil
                Task { await distrust(peer) }
            }
            Button("Cancel", role: .cancel) { peerToDistrust = nil }
        } message: {
            Text("This ends trust in both directions for observers that accept the revocation. The instance can be verified again later.")
        }
        // Asked before the sign-in tab opens, when the account's server
        // cannot grant the profile-space permission.
        .confirmationDialog(
            "Sign in without profile sync?",
            isPresented: Binding(
                get: { app.profileAccount.signInConfirmation != nil },
                // Dismissing without choosing is Cancel. The buttons answer
                // first; this only answers if neither did.
                set: { presented in
                    guard !presented else { return }
                    Task { @MainActor in
                        if app.profileAccount.signInConfirmation != nil {
                            app.profileAccount.answerSignInConfirmation(false)
                        }
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign In") { app.profileAccount.answerSignInConfirmation(true) }
            Button("Cancel", role: .cancel) { app.profileAccount.answerSignInConfirmation(false) }
        } message: {
            Text(app.profileAccount.signInConfirmation ?? "")
        }
    }

    @ViewBuilder private var accountControls: some View {
        if let account = app.profileAccount.account {
            LabeledContent("Account", value: app.profileAccount.handle ?? account.rawValue)
            let profileSyncNotice = app.profileAccount.profileSyncNotice
            if let profileSyncNotice {
                Label(profileSyncNotice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            // The sync service also syncs with local devices. Without profile
            // sync, its status and Sync Now only concern those, so they're
            // shown (and named) only while local network sync is on here.
            let localOnly = profileSyncNotice != nil
            if !localOnly || app.localNetworkSync.isOnHere {
                if let sync = app.profileAccount.syncService {
                    switch sync.state {
                    case .idle:
                        Text(sync.lastSyncedAt == nil
                             ? (localOnly ? "Ready to sync with local devices" : "Ready to sync")
                             : (localOnly ? "Synced with local devices" : "Synced"))
                    case .syncing: ProgressView(localOnly ? "Syncing with local devices…" : "Syncing…")
                    case .offline: Text("Offline — changes are queued")
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    }
                }
                Button(localOnly ? "Sync with Local Devices" : "Sync Now") {
                    Task {
                        await app.profileAccount.sync()
                        await reload()
                    }
                }
            }
            Button("Sign Out", role: .destructive) {
                app.profileAccount.signOut()
                peers = []
            }
        } else {
            TextField("Handle or DID", text: $accountIdentifier)
                .settingsTextEntryStyle()
                // A handle or DID is an identifier, not prose.
                .autocorrectionDisabled()
            Button("Sign In with AT Protocol") {
                Task {
                    await app.profileAccount.signIn(identifier: accountIdentifier)
                    await reload()
                }
            }
            .disabled(app.profileAccount.isSigningIn || accountIdentifier.isEmpty)
            if app.profileAccount.isSigningIn { ProgressView("Opening your account provider…") }
            if let message = app.profileAccount.errorMessage {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    private var emptyDescription: String {
        app.profileAccount.account == nil
            ? "Your local profile is ready. Sign in to discover app-compatible instances through AppSync."
            : "Other Hummingbird instances will appear here after they register with AppSync."
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { peers = try await app.profileAccount.peers() }
        catch { errorMessage = error.localizedDescription }
    }

    private func verify(_ value: String) async {
        guard let code = AppSyncPeerVerificationCode(rawValue: value) else {
            errorMessage = AppSyncPeerVerificationError.invalidCode.localizedDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await app.profileAccount.verifyPeer(code)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    private func compareEmoji(with peer: AppSyncPeerTrustSummary) async {
        errorMessage = nil
        do { try await app.profileAccount.startVerification(with: peer) }
        catch { errorMessage = error.localizedDescription }
    }

    private func distrust(_ summary: AppSyncPeerTrustSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await app.profileAccount.distrustPeer(summary.peer)
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct PeerVerificationCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let code: AppSyncPeerVerificationCode

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let qr = try? QRCode.encode(text: code.rawValue, ecl: .medium) {
                    PeerQRCode(code: qr).frame(maxWidth: 420)
                }
                Text("Scan this code on another instance, or click the code to copy it and enter it there.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                CopyButton(code.rawValue) {
                    Text(code.rawValue).font(.caption.monospaced())
                }
            }
            .padding()
            .navigationTitle("Verify This Instance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct PeerQRCode: View {
    let code: QRCode

    var body: some View {
        Canvas { context, size in
            let quietZone = 4
            let count = code.size + quietZone * 2
            let scale = min(size.width, size.height) / CGFloat(count)
            var background = Path()
            background.addRect(CGRect(origin: .zero, size: size))
            context.fill(background, with: .color(.white))
            var modules = Path()
            for y in 0..<code.size {
                for x in 0..<code.size where code.getModule(x: x, y: y) {
                    modules.addRect(CGRect(
                        x: CGFloat(x + quietZone) * scale,
                        y: CGFloat(y + quietZone) * scale,
                        width: scale + 0.25, height: scale + 0.25
                    ))
                }
            }
            context.fill(modules, with: .color(.black))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Peer verification QR code")
    }
}

@MainActor
private struct PeerTrustRow: View {
    let peer: AppSyncPeerTrustSummary
    let compareEmoji: () -> Void
    let scan: () -> Void
    let enterCode: () -> Void
    let distrust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeerIdentityLabel(peerID: peer.id)
            Label(statusText, systemImage: statusIcon).font(.subheadline).foregroundStyle(statusColor)
            if !peer.isReachable {
                Label("Not reachable right now", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .indirectlyTrusted(let path) = peer.state {
                Text("Trusted through \(max(0, path.count - 2)) intermediate instance\(path.count == 3 ? "" : "s"). Sync remains enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                // Verifying needs the instance's current registration.
                if peer.isReachable, peer.recommendation != nil || isExplicitlyDistrusted {
                    Menu("Verify Directly") {
                        Button("Compare Emoji", action: compareEmoji)
                        Button("Scan Its Code", action: scan)
                        Button("Enter Its Code", action: enterCode)
                    }
                }
                if !isExplicitlyDistrusted { Button("Distrust", role: .destructive, action: distrust) }
            }
        }
        .padding(.vertical, 4)
    }

    private var isExplicitlyDistrusted: Bool {
        if case .explicitlyDistrusted = peer.state { return true }
        return false
    }

    private var statusText: String {
        switch peer.state {
        case .local: "This instance"
        case .directlyTrusted: "Directly trusted"
        case .indirectlyTrusted: "Indirectly trusted"
        case .explicitlyDistrusted: "Explicitly distrusted"
        case .implicitlyDistrusted: "No longer trusted indirectly"
        case .unknown: "Not yet verified"
        }
    }

    private var statusIcon: String {
        switch peer.state {
        case .local, .directlyTrusted: "checkmark.shield.fill"
        case .indirectlyTrusted: "person.line.dotted.person.fill"
        case .explicitlyDistrusted, .implicitlyDistrusted: "xmark.shield.fill"
        case .unknown: "questionmark.diamond"
        }
    }

    private var statusColor: Color {
        switch peer.state {
        case .local, .directlyTrusted, .indirectlyTrusted: .green
        case .explicitlyDistrusted, .implicitlyDistrusted: .red
        case .unknown: .secondary
        }
    }
}

@MainActor
private struct PeerIdentityLabel: View {
    let peerID: AppSyncPeerID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Instance \(peerID.rawValue.prefix(8))").font(.headline)
            Text(peerID.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                .copyableText()
        }
    }
}
