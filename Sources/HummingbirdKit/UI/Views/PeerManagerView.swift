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
                                get: { app.localNetworkSyncEnabled },
                                set: { app.setLocalNetworkSyncEnabled($0) }
                            )
                        )
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
                            Text("Local peer identity is unavailable.").foregroundStyle(.secondary)
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
                                    verify: { isScanning = true },
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
        .toolbar {
            if !isScanning {
                ToolbarItem(placement: .primaryAction) {
                    Button { isScanning = true } label: {
                        Label("Verify instance", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(!QRCodeScanning.isAvailable || app.peerService == nil)
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showingLocalCode) {
            if let service = app.peerService {
                PeerVerificationCodeSheet(code: service.verificationCode)
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
    }

    @ViewBuilder private var accountControls: some View {
        if let account = app.profileAccount.account {
            LabeledContent("Account", value: app.profileAccount.handle ?? account.rawValue)
            if let sync = app.profileAccount.syncService {
                switch sync.state {
                case .idle: Text(sync.lastSyncedAt == nil ? "Ready to sync" : "Synced")
                case .syncing: ProgressView("Syncing…")
                case .offline: Text("Offline — changes are queued")
                case .failed(let message): Text(message).foregroundStyle(.red)
                }
            }
            Button("Sync Now") {
                Task {
                    await app.profileAccount.sync()
                    await reload()
                }
            }
            Button("Sign Out", role: .destructive) {
                app.profileAccount.signOut()
                peers = []
            }
        } else {
            TextField("Handle or DID", text: $accountIdentifier)
                .settingsTextEntryStyle()
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
                Text("Scan this code on another instance to verify this instance directly.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(code.rawValue).font(.caption.monospaced()).textSelection(.enabled)
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
    let verify: () -> Void
    let distrust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeerIdentityLabel(peerID: peer.id)
            Label(statusText, systemImage: statusIcon).font(.subheadline).foregroundStyle(statusColor)
            if case .indirectlyTrusted(let path) = peer.state {
                Text("Trusted through \(max(0, path.count - 2)) intermediate instance\(path.count == 3 ? "" : "s"). Sync remains enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if peer.recommendation != nil || isExplicitlyDistrusted {
                    Button("Verify Directly", action: verify)
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
                .textSelection(.enabled)
        }
    }
}
