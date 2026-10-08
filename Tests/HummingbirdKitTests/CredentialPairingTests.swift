import XCTest
@testable import HummingbirdKit

final class CredentialPairingTests: XCTestCase {
    private let endpoint = URL(string: "http://living-room.local:32123/credentials")!
    private let source = URL(string: "https://plugins.example.test/nebula.json")!
    private let secret = Data(0..<32)

    func testPairingURLRoundTripsAllConnectionDetails() throws {
        let request = CredentialPairingRequest(
            endpoint: endpoint, secret: secret, pluginID: "nebula", pluginSourceURL: source
        )

        let decoded = try XCTUnwrap(CredentialPairingRequest(url: request.url))
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.verificationEmoji, request.verificationEmoji)
        XCTAssertEqual(request.verificationEmoji.split(separator: " ").count, 7)
    }

    func testCredentialsAreEncryptedAndAuthenticated() throws {
        let request = CredentialPairingRequest(
            endpoint: endpoint, secret: secret, pluginID: "nebula", pluginSourceURL: source
        )
        let auth = SourceAuth(
            cookieMap: ["nebula.tv": ["session": "private-value"]],
            headers: ["nebula.tv": ["authorization": "Bearer token"]],
            userAgent: "Hummingbird Test"
        )

        let ciphertext = try request.encrypted(auth)
        XCTAssertFalse(String(data: ciphertext, encoding: .utf8)?.contains("private-value") == true)
        XCTAssertEqual(try request.decrypt(ciphertext), auth)

        var tampered = ciphertext
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try request.decrypt(tampered))
    }

    @MainActor
    func testReceiverAcceptsOneEncryptedCredentialTransfer() async throws {
        let received = expectation(description: "receiver callback")
        let auth = SourceAuth(cookieMap: ["nebula.tv": ["session": "paired"]])
        var receivedAuth: SourceAuth?
        let receiver = CredentialPairingReceiver(pluginID: "nebula", pluginSourceURL: source) { value in
            receivedAuth = value
            received.fulfill()
        }
        defer { receiver.stop() }

        let advertised = try await receiver.start()
        var local = URLComponents(url: advertised.endpoint, resolvingAgainstBaseURL: false)!
        local.host = "127.0.0.1"
        let request = CredentialPairingRequest(
            endpoint: try XCTUnwrap(local.url), secret: advertised.secret,
            pluginID: advertised.pluginID, pluginSourceURL: advertised.pluginSourceURL
        )
        do {
            try await request.send(auth)
            XCTFail("The receiver accepted credentials before local verification")
        } catch {
            XCTAssertEqual(error as? PairingError, .rejected)
        }
        receiver.confirmVerification()
        let acceptedStatus = try await request.remoteStatus()
        XCTAssertEqual(acceptedStatus, .accepted)
        try await request.send(auth)
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(receivedAuth, auth)
    }

    @MainActor
    func testEitherDeviceCanRejectAnEmojiMismatch() async throws {
        let rejected = expectation(description: "remote rejection callback")
        let receiver = CredentialPairingReceiver(
            pluginID: "nebula", pluginSourceURL: source,
            onReceive: { _ in XCTFail("Rejection delivered credentials") },
            onReject: { rejected.fulfill() }
        )
        defer { receiver.stop() }
        let advertised = try await receiver.start()
        var local = URLComponents(url: advertised.endpoint, resolvingAgainstBaseURL: false)!
        local.host = "127.0.0.1"
        let request = CredentialPairingRequest(
            endpoint: try XCTUnwrap(local.url), secret: advertised.secret,
            pluginID: advertised.pluginID, pluginSourceURL: advertised.pluginSourceURL
        )

        let initialStatus = try await request.remoteStatus()
        XCTAssertEqual(initialStatus, .waiting)
        try await request.reject()
        await fulfillment(of: [rejected], timeout: 2)
        let rejectedStatus = try await request.remoteStatus()
        XCTAssertEqual(rejectedStatus, .rejected)

        let localReceiver = CredentialPairingReceiver(pluginID: "nebula", pluginSourceURL: source, onReceive: { _ in })
        defer { localReceiver.stop() }
        let localAdvertised = try await localReceiver.start()
        var localStatus = URLComponents(url: localAdvertised.endpoint, resolvingAgainstBaseURL: false)!
        localStatus.host = "127.0.0.1"
        let localRequest = CredentialPairingRequest(
            endpoint: try XCTUnwrap(localStatus.url), secret: localAdvertised.secret,
            pluginID: localAdvertised.pluginID, pluginSourceURL: localAdvertised.pluginSourceURL
        )
        localReceiver.rejectVerification()
        let locallyRejectedStatus = try await localRequest.remoteStatus()
        XCTAssertEqual(locallyRejectedStatus, .rejected)
    }
}
