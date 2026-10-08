import Foundation
#if !canImport(WebKit)
import Observation
import QRCodeGenerator
import SwiftOpenUI

/// On tvOS, hands a fresh isolated browser login to another Hummingbird device.
@MainActor
struct WebAuthSheet: View {
    let spec: WebAuthSpec
    let onFinish: (SourceAuth?) -> Void
    @State private var pairing: CredentialPairingModel

    init(spec: WebAuthSpec, onFinish: @escaping (SourceAuth?) -> Void) {
        self.spec = spec
        self.onFinish = onFinish
        _pairing = State(wrappedValue: CredentialPairingModel(
            pluginID: spec.pluginID, sourceURL: spec.pluginSourceURL, onFinish: onFinish
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let request = pairing.request, let code = try? QRCode.encode(text: request.url.absoluteString, ecl: .medium) {
                    Text("Scan with a device that has Hummingbird installed")
                        .font(.headline)
                    PairingQRCode(code: code)
                        .frame(maxWidth: 440, maxHeight: 440)
                        .padding(20)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    Text("A new private sign-in window will open on that device. This code expires after 10 minutes.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(request.verificationEmoji)
                        .font(.title2)
                        .accessibilityLabel("Verification emoji: \(request.verificationEmoji)")
                    Text("Confirm only if these emoji match the other device.")
                        .foregroundStyle(.secondary)
                    Button(pairing.confirmed ? "Emoji confirmed" : "They match") {
                        pairing.confirm()
                    }
                    .disabled(pairing.confirmed)
                    Button("They don’t match", role: .destructive) { pairing.reject() }
                        .disabled(pairing.confirmed)
                } else if let error = pairing.error {
                    ContentUnavailableView("Pairing unavailable", systemImage: "qrcode",
                                           description: Text(error))
                } else {
                    ProgressView("Creating secure sign-in code…")
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish(nil) }
                }
            }
            .navigationTitle(spec.title)
            .task { await pairing.start() }
            .onDisappear { pairing.stop() }
        }
    }
}

@MainActor
@Observable
private final class CredentialPairingModel {
    private let sourceURL: URL?
    private let pluginID: String?
    private let onFinish: (SourceAuth?) -> Void
    private var receiver: CredentialPairingReceiver?
    private(set) var request: CredentialPairingRequest?
    private(set) var error: String?
    private(set) var confirmed = false

    init(pluginID: String?, sourceURL: URL?, onFinish: @escaping (SourceAuth?) -> Void) {
        self.pluginID = pluginID
        self.sourceURL = sourceURL
        self.onFinish = onFinish
    }

    func start() async {
        guard request == nil, error == nil, receiver == nil else { return }
        guard let pluginID, let sourceURL else {
            error = "This plugin has no source URL to share with the sign-in device."
            return
        }
        let receiver = CredentialPairingReceiver(
            pluginID: pluginID,
            pluginSourceURL: sourceURL,
            onReceive: { [weak self] auth in self?.onFinish(auth) },
            onReject: { [weak self] in self?.error = "The other device reported that the verification emoji did not match." }
        )
        self.receiver = receiver
        do { request = try await receiver.start() }
        catch { self.error = error.localizedDescription; self.receiver = nil }
    }

    func stop() {
        receiver?.stop()
        receiver = nil
    }

    func confirm() {
        receiver?.confirmVerification()
        confirmed = true
    }

    func reject() {
        receiver?.rejectVerification()
        error = "Pairing rejected because the verification emoji did not match."
    }
}

private struct PairingQRCode: View {
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
                        width: scale + 0.25,
                        height: scale + 0.25
                    ))
                }
            }
            context.fill(modules, with: .color(.black))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Credential sign-in QR code")
    }
}
#endif
