#if os(macOS) && !BACKEND_GTK
import CredentialStorage
import Foundation
import SwiftOpenUI

/// A storage question that must be answered before Hummingbird opens a
/// profile, because opening one reads and writes credentials.
public enum CredentialStorageDecision: Equatable, Sendable {
    /// The Data Protection Keychain is unavailable and the user has not said
    /// whether the login keychain may be used.
    case fallbackConsent(CredentialVaultError)
    /// The Data Protection Keychain works again and login-keychain items
    /// remain from the fallback.
    case migration(count: Int)
    /// The login keychain could not be checked for items to migrate.
    case migrationCheckFailed(String)

    /// The question to ask now, if any. Probes the store (writing only a
    /// non-secret marker item), so call it before any secret is stored.
    public static func pending(for store: KeychainCredentialStore) -> Self? {
        if case .fallbackConsentRequired(let error) = store.status { return .fallbackConsent(error) }
        do {
            let candidates = try store.migrationCandidates()
            return candidates.isEmpty ? nil : .migration(count: candidates.count)
        } catch {
            return .migrationCheckFailed(error.localizedDescription)
        }
    }
}

enum LoginKeychainFallbackText {
    static let title = "Allow the less secure login keychain?"

    static func unavailable(_ error: CredentialVaultError) -> String {
        "Hummingbird keeps your AT Protocol sign-in, sync keys and plugin sign-ins in the protected "
            + "data-protection keychain. This copy of Hummingbird can’t use it — macOS reported "
            + "“\(error.localizedDescription)”. That happens when the app isn’t signed by an Apple "
            + "development team, for example when it’s built from source."
    }

    static let alternative = "Hummingbird can keep them in your login keychain instead. This is much less secure:"

    static let risks = [
        "Items aren’t sandboxed to Hummingbird or its developer; they sit in your login keychain "
            + "alongside other apps’ passwords.",
        "Access is controlled by keychain permissions tied to this build’s code signature. Builds signed "
            + "ad hoc get a new signature every time they’re rebuilt, so macOS may ask you to allow keychain "
            + "access again after each update.",
        "Any other app you approve at those prompts can read these items.",
        "There’s no shared access group, so other Hummingbird installs and extensions can’t share these items.",
    ]

    static let consequence = "If you don’t allow this, Hummingbird still opens, but sign-ins, plugin "
        + "credentials and sync stay unavailable. This choice applies only to this Mac, and you can change "
        + "it in Settings under Credential Storage."

    static let allow = "Use Login Keychain"
    static let decline = "Don’t Allow"
}

/// The opt-in prompt. Nothing is written to the login keychain unless the
/// user presses the allow button.
struct LoginKeychainFallbackConsentView: View {
    let error: CredentialVaultError
    let onAllow: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LoginKeychainFallbackText.title, systemImage: "exclamationmark.lock")
                .font(.title2.bold())
            Text(LoginKeychainFallbackText.unavailable(error))
            Text(LoginKeychainFallbackText.alternative)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LoginKeychainFallbackText.risks, id: \.self) { risk in
                    Label(risk, systemImage: "exclamationmark.triangle")
                }
            }
            Text(LoginKeychainFallbackText.consequence).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(LoginKeychainFallbackText.decline, role: .cancel, action: onDecline)
                    .keyboardShortcut(.cancelAction)
                Button(LoginKeychainFallbackText.allow, action: onAllow)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 560)
        .padding()
    }
}

/// Asks the pending storage question at launch, before a profile is opened.
public struct CredentialStorageDecisionView: View {
    let decision: CredentialStorageDecision
    let store: KeychainCredentialStore
    let onResolved: () -> Void
    @State private var failure: String?
    @State private var isMigrating = false

    public init(decision: CredentialStorageDecision, store: KeychainCredentialStore,
                onResolved: @escaping () -> Void) {
        self.decision = decision
        self.store = store
        self.onResolved = onResolved
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch decision {
                case .fallbackConsent(let error):
                    LoginKeychainFallbackConsentView(
                        error: error,
                        onAllow: { store.setLoginKeychainFallbackAllowed(true); onResolved() },
                        onDecline: { store.setLoginKeychainFallbackAllowed(false); onResolved() }
                    )
                case .migration(let count):
                    migrationPrompt(count: count)
                case .migrationCheckFailed(let message):
                    Label("Hummingbird couldn’t check your login keychain", systemImage: "exclamationmark.triangle")
                        .font(.title2.bold())
                    Text("Credentials left there from the less secure fallback can’t be moved to the protected "
                         + "keychain right now: \(message)")
                    HStack {
                        Spacer()
                        Button("Continue", action: onResolved).keyboardShortcut(.defaultAction)
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 560)
            .padding()
        }
    }

    @ViewBuilder
    private func migrationPrompt(count: Int) -> some View {
        Label("Move credentials to the protected keychain?", systemImage: "lock.shield")
            .font(.title2.bold())
        Text("Hummingbird can use the protected data-protection keychain again. "
             + "\(count == 1 ? "1 item is" : "\(count) items are") still in your login keychain from when you "
             + "allowed the less secure fallback, and Hummingbird won’t use them there. Moving them stores them "
             + "in the protected keychain and deletes the login-keychain copies. macOS may ask you to allow "
             + "access to each item.")
        HStack {
            Spacer()
            Button("Not Now", role: .cancel, action: onResolved).disabled(isMigrating)
            Button("Move Credentials") {
                isMigrating = true
                Task {
                    let store = store
                    let result = await Task.detached { Result { try store.migrateLoginKeychainItems() } }.value
                    isMigrating = false
                    switch result {
                    case .success: onResolved()
                    case .failure(let error):
                        failure = "Some credentials couldn’t be moved and were left in the login keychain: "
                            + error.localizedDescription
                    }
                }
            }
            .disabled(isMigrating)
        }
    }
}

/// Settings for where credentials are stored on this Mac, including revoking
/// the login-keychain fallback.
struct CredentialStorageSettingsSection: View {
    let store: KeychainCredentialStore
    @State private var revision = 0
    @State private var showingConsent = false
    @State private var confirmingRevoke = false
    /// Composed when the toggle is switched off, not while rendering: it
    /// lists keychain items.
    @State private var revokeMessage = ""
    @State private var message: String?

    var body: some View {
        let _ = revision
        let status = store.status
        let consent = store.loginKeychainFallbackConsent
        Section {
            LabeledContent("Store", value: Self.summary(of: status))
            if let failure = Self.failure(of: status) {
                Text(failure).font(.footnote).foregroundStyle(.secondary)
            }
            if status != .dataProtection || consent == .accepted {
                Toggle("Allow login keychain fallback", isOn: Binding(
                    get: { consent == .accepted },
                    set: { allowed in
                        if allowed {
                            showingConsent = true
                        } else {
                            revokeMessage = Self.composeRevokeMessage(store: store, status: status)
                            confirmingRevoke = true
                        }
                    }
                ))
            }
            if status == .dataProtection, consent == .accepted {
                Button("Move Credentials to Protected Keychain") { migrate() }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Credential Storage")
        } footer: {
            Text("Hummingbird prefers the protected data-protection keychain. The login keychain is used only "
                 + "if you allow it on this Mac, and is much less secure.")
        }
        .sheet(isPresented: $showingConsent) {
            if let error = Self.vaultError(of: status) {
                LoginKeychainFallbackConsentView(
                    error: error,
                    onAllow: {
                        store.setLoginKeychainFallbackAllowed(true)
                        showingConsent = false
                        changed("Quit and reopen Hummingbird to start using the login keychain.")
                    },
                    onDecline: { showingConsent = false }
                )
                .sheetSize()
            }
        }
        .alert("Stop using the login keychain?", isPresented: $confirmingRevoke) {
            Button("Cancel", role: .cancel) {}
            Button("Delete and Stop Using", role: .destructive) { revoke() }
        } message: {
            Text(revokeMessage)
        }
    }

    private func revoke() {
        do {
            try store.revokeLoginKeychainFallback()
            changed("Hummingbird’s items were deleted from the login keychain. Quit and reopen Hummingbird to "
                    + "apply this change.")
        } catch {
            changed("Hummingbird stopped using the login keychain, but couldn’t delete all of its items there: "
                    + error.localizedDescription)
        }
    }

    private func migrate() {
        do {
            let count = try store.migrateLoginKeychainItems()
            changed("Moved \(count) item\(count == 1 ? "" : "s") to the protected keychain and deleted the "
                    + "login-keychain copies.")
        } catch {
            changed("Some credentials couldn’t be moved and were left in the login keychain: "
                    + error.localizedDescription)
        }
    }

    private func changed(_ text: String) {
        message = text
        revision &+= 1
    }

    private static func composeRevokeMessage(store: KeychainCredentialStore, status: CredentialStoreStatus) -> String {
        let items: String
        do {
            let count = try store.loginKeychainItemAccounts().count
            items = count == 1 ? "the 1 item" : "the \(count) items"
        } catch {
            items = "the items"
        }
        let effect = status == .dataProtection
            ? "Hummingbird keeps using the protected keychain. Anything not yet moved there is lost, and you "
                + "may need to sign in again."
            : "Until the protected keychain can be used, sign-ins, plugin credentials and sync will be "
                + "unavailable."
        return "Hummingbird will delete \(items) it keeps in your login keychain. \(effect)"
    }

    private static func summary(of status: CredentialStoreStatus) -> String {
        switch status {
        case .dataProtection: "Protected keychain"
        case .loginKeychainFallback: "Login keychain (less secure)"
        case .fallbackConsentRequired, .fallbackDeclined, .unavailable: "Unavailable"
        }
    }

    private static func failure(of status: CredentialStoreStatus) -> String? {
        switch status {
        case .dataProtection, .loginKeychainFallback: nil
        case .fallbackConsentRequired(let error):
            CredentialStoreAccessError.fallbackConsentRequired(error).localizedDescription
        case .fallbackDeclined(let error):
            CredentialStoreAccessError.fallbackDeclined(error).localizedDescription
        case .unavailable(let error):
            CredentialStoreAccessError.protectedStoreUnavailable(error).localizedDescription
        }
    }

    private static func vaultError(of status: CredentialStoreStatus) -> CredentialVaultError? {
        switch status {
        case .dataProtection: nil
        case .unavailable(let error), .loginKeychainFallback(let error),
             .fallbackConsentRequired(let error), .fallbackDeclined(let error): error
        }
    }
}
#endif
