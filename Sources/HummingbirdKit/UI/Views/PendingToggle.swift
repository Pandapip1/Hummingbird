import Foundation
import SwiftOpenUI

// Controls for settings whose change takes a while to apply. None of them
// pretends a change happened before it has: while `apply` runs, the control
// takes no input, a spinner and "Applying…" show what is happening, and
// afterwards it shows the value actually in effect, which is the old one,
// with the error below it, if applying failed.

/// A toggle that waits for its change to apply. In between, the switch shows
/// neither on nor off. The in-between switch is drawn from shapes, so it
/// looks the same on every platform, whether or not the platform's own
/// switch has a mixed state.
@MainActor
struct PendingToggle<Label: View>: View {
    let title: String
    let isOn: Bool
    let apply: @MainActor (Bool) async throws -> Void
    @ViewBuilder let label: () -> Label
    @State private var applying = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if applying {
                HStack(spacing: 8) {
                    label()
                    Spacer(minLength: 8)
                    IndeterminateSwitch()
                    ProgressView()
                }
                .accessibilityLabel(title)
                .accessibilityValue("Applying…")
            } else {
                Toggle(isOn: Binding(get: { isOn }, set: { value in
                    guard value != isOn, !applying else { return }
                    applying = true
                    failure = nil
                    Task {
                        do { try await apply(value) } catch { failure = error.localizedDescription }
                        applying = false
                    }
                }), label: label)
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? "On" : "Off")
            }
            PendingFailure(message: failure)
        }
    }
}

/// A choice that waits for its change to apply. In between, it keeps
/// showing the choice in effect, disabled, with a spinner beside it.
@MainActor
struct PendingPicker<Options: View>: View {
    let title: String
    let selection: Int
    let apply: @MainActor (Int) async throws -> Void
    @ViewBuilder let options: () -> Options
    @State private var applying = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker(title, selection: Binding(get: { selection }, set: { value in
                    guard value != selection, !applying else { return }
                    applying = true
                    failure = nil
                    Task {
                        do { try await apply(value) } catch { failure = error.localizedDescription }
                        applying = false
                    }
                }), content: options)
                .disabled(applying)
                if applying { PendingIndicator() }
            }
            .accessibilityLabel(title)
            .accessibilityValue(applying ? "Applying…" : "")
            PendingFailure(message: failure)
        }
    }
}

/// Text that is applied when submitted, not keystroke by keystroke. While it
/// applies, the field takes no input; if applying fails, the field goes back
/// to the text in effect.
@MainActor
struct PendingTextField: View {
    let title: String
    let text: String
    let apply: @MainActor (String) async throws -> Void
    @State private var draft: String?
    @State private var applying = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(title, text: Binding(get: { draft ?? text }, set: { draft = $0 }))
                    .settingsTextEntryStyle()
                    .onSubmit(submit)
                    .disabled(applying)
                if applying { PendingIndicator() }
            }
            .accessibilityLabel(title)
            .accessibilityValue(applying ? "Applying…" : "")
            PendingFailure(message: failure)
        }
    }

    private func submit() {
        guard !applying else { return }
        guard let value = draft, value != text else {
            draft = nil
            return
        }
        applying = true
        failure = nil
        Task {
            do { try await apply(value) } catch { failure = error.localizedDescription }
            // Either way the field shows the text in effect.
            draft = nil
            applying = false
        }
    }
}

private struct PendingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
            Text("Applying…").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PendingFailure: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(.red)
        }
    }
}

/// A switch that is neither on nor off: a neutral track with a dash.
private struct IndeterminateSwitch: View {
    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 44, height: 26)
            .overlay(Capsule().fill(Color.secondary).frame(width: 14, height: 3))
    }
}
