import SwiftOpenUI

extension View {
    /// Shows the permission gate's explanation before a settings-driven system
    /// prompt. Every button answers the gate; dismissing counts as "Not Now".
    @MainActor
    func permissionPrompts(_ gate: PermissionGate) -> some View {
        alert(
            gate.prompt?.explanation.title ?? "",
            isPresented: Binding(
                get: { gate.prompt != nil },
                // The buttons answer; a dismissal runs the cancel button.
                set: { _ in }
            ),
            presenting: gate.prompt
        ) { prompt in
            Button(prompt.explanation.continueTitle) { gate.respond(.continue) }
            Button(prompt.explanation.declineTitle, role: .destructive) { gate.respond(.offOnThisDevice) }
            Button(prompt.explanation.deferTitle, role: .cancel) { gate.respond(.notNow) }
        } message: { prompt in
            Text(prompt.explanation.message)
        }
    }
}
