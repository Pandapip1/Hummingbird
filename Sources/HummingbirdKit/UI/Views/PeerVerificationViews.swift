import ATAppSync
import Foundation
import SwiftOpenUI

extension View {
    /// Shows emoji verifications with other instances, including ones another
    /// instance starts, wherever the user is in the app.
    func peerVerificationPrompts(_ account: ProfileAccountService) -> some View {
        modifier(PeerVerificationPrompts(account: account))
    }
}

@MainActor
private struct PeerVerificationPrompts: ViewModifier {
    let account: ProfileAccountService

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { account.verifications.first },
                set: { dismissed in
                    if dismissed == nil, let current = account.verifications.first {
                        finish(current)
                    }
                }
            )) { verification in
                PeerVerificationSheet(
                    verification: verification,
                    confirm: { try await account.confirmVerification(verification.id) },
                    cancel: { await account.cancelVerification(verification.id) },
                    done: { account.dismissVerification(verification.id) }
                )
            }
            .task { account.watchVerifications() }
    }

    /// Closing the sheet mid-verification cancels it on both instances.
    private func finish(_ verification: AppSyncPeerVerification) {
        switch verification.phase {
        case .verified, .cancelled:
            account.dismissVerification(verification.id)
        case .exchangingKeys, .comparing, .waitingForPeer:
            Task {
                await account.cancelVerification(verification.id)
                account.dismissVerification(verification.id)
            }
        }
    }
}

@MainActor
private struct PeerVerificationSheet: View {
    let verification: AppSyncPeerVerification
    let confirm: () async throws -> Void
    let cancel: () async -> Void
    let done: () -> Void
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Instance \(verification.peer.stableID.rawValue.prefix(8))")
                    .font(.headline)
                content
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            .navigationTitle("Verify Instance")
        }
        .sheetSize()
    }

    @ViewBuilder private var content: some View {
        switch verification.phase {
        case .exchangingKeys:
            ProgressView(verification.role == .initiator
                         ? "Contacting the other instance…" : "Waiting for the other instance…")
            Button("Cancel", role: .cancel) { run { await cancel() } }
        case .comparing:
            Text("Check that the other instance shows the same emoji, in the same order.")
                .foregroundStyle(.secondary)
            emojiRow
            HStack {
                Button("They Don’t Match", role: .destructive) { run { await cancel() } }
                Button("They Match") { run { try await confirm() } }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(working)
            if working { ProgressView() }
        case .waitingForPeer:
            emojiRow
            ProgressView("Waiting for you to confirm on the other instance…")
            Button("Cancel", role: .cancel) { run { await cancel() } }
        case .verified:
            Label("Verified. These instances now trust each other.", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Button("Done", action: done).buttonStyle(.borderedProminent)
        case .cancelled(let reason):
            Label(reason, systemImage: "xmark.shield")
                .foregroundStyle(.red)
            Button("Close", action: done)
        }
    }

    @ViewBuilder private var emojiRow: some View {
        if let emoji = verification.emoji {
            Text(emoji.joined(separator: " "))
                .font(.system(size: 40))
                .accessibilityLabel("Verification emoji: \(emoji.joined(separator: ", "))")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}
