import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ATProtoKit

private struct FakeDNS: DNSTXTResolving {
    var answers: [String: Result<[String], any Error>] = [:]
    func txtRecords(for name: String) async throws -> [String] {
        try (answers[name] ?? .success([])).get()
    }
}

private struct FakeWeb: Sendable {
    var documents: [String: (status: Int, body: String)] = [:]
    var fetch: ATProtoIdentityResolver.Fetch {
        let documents = documents
        return { url in
            guard let document = documents[url.absoluteString] else { throw URLError(.cannotFindHost) }
            let response = HTTPURLResponse(url: url, statusCode: document.status, httpVersion: nil, headerFields: nil)!
            return (Data(document.body.utf8), response)
        }
    }
}

private func didDocument(_ did: String, aliases: [String]) -> String {
    let aliasList = aliases.map { "\"\($0)\"" }.joined(separator: ",")
    return """
    {"id":"\(did)","alsoKnownAs":[\(aliasList)],
     "service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.net"}]}
    """
}

private struct LookupFailed: Error {}

final class HandleResolutionTests: XCTestCase {
    private let did = "did:plc:abc123"

    // MARK: TXT parsing

    func testTXTRDataJoinsCharacterStrings() {
        let rdata: [UInt8] = [4] + Array("did=".utf8) + [14] + Array("did:plc:abc123".utf8)
        XCTAssertEqual(DNSTXT.value(ofRData: rdata), "did=did:plc:abc123")
        XCTAssertEqual(DNSTXT.value(ofRData: [UInt8]()), "")
    }

    func testTXTRDataRejectsTruncatedStrings() {
        XCTAssertNil(DNSTXT.value(ofRData: [5] + Array("did".utf8)))
        XCTAssertNil(DNSTXT.value(ofRData: [2, 0xFF, 0xFE]))
    }

    func testDIDFromTXTIgnoresOtherRecords() throws {
        XCTAssertEqual(
            try ATProtoIdentityResolver.did(fromTXT: ["v=spf1 -all", "did=\(did)", "did=not a did"])?.rawValue,
            did
        )
        XCTAssertNil(try ATProtoIdentityResolver.did(fromTXT: ["v=spf1 -all", "DID=\(did)"]))
        XCTAssertNil(try ATProtoIdentityResolver.did(fromTXT: []))
    }

    func testDuplicateTXTRecordsForOneDIDAreAccepted() throws {
        XCTAssertEqual(try ATProtoIdentityResolver.did(fromTXT: ["did=\(did)", "did=\(did)"])?.rawValue, did)
    }

    func testConflictingTXTRecordsAreRejected() {
        XCTAssertThrowsError(try ATProtoIdentityResolver.did(fromTXT: ["did=\(did)", "did=did:plc:other"]))
    }

    func testHandleSyntax() {
        XCTAssertTrue(ATProtoIdentityResolver.isValidHandle("alice.example.com"))
        XCTAssertTrue(ATProtoIdentityResolver.isValidHandle("xn--ls8h.test"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("localhost"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("alice..example.com"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("-alice.example.com"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("alice.example.123"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("alice.example.com/evil"))
        XCTAssertFalse(ATProtoIdentityResolver.isValidHandle("alice@example.com"))
    }

    // MARK: Resolution order

    func testDNSRecordResolvesWithoutHTTPS() async throws {
        let dns = FakeDNS(answers: ["_atproto.alice.example.com": .success(["did=\(did)"])])
        let web = FakeWeb(documents: [
            "https://plc.directory/\(did)": (200, didDocument(did, aliases: ["at://alice.example.com"])),
        ])
        let identity = try await ATProtoIdentityResolver(dns: dns, fetch: web.fetch).resolve("@Alice.Example.com")
        XCTAssertEqual(identity.did.rawValue, did)
        XCTAssertEqual(identity.handle, "alice.example.com")
        XCTAssertEqual(identity.pds.absoluteString, "https://pds.example.net")
    }

    func testHTTPSIsUsedWhenThereIsNoDNSRecord() async throws {
        let web = FakeWeb(documents: [
            "https://alice.example.com/.well-known/atproto-did": (200, "\(did)\n"),
            "https://plc.directory/\(did)": (200, didDocument(did, aliases: ["at://alice.example.com"])),
        ])
        let identity = try await ATProtoIdentityResolver(dns: FakeDNS(), fetch: web.fetch).resolve("alice.example.com")
        XCTAssertEqual(identity.did.rawValue, did)
    }

    func testHTTPSIsUsedWhenTheDNSLookupFails() async throws {
        let dns = FakeDNS(answers: ["_atproto.alice.example.com": .failure(LookupFailed())])
        let web = FakeWeb(documents: [
            "https://alice.example.com/.well-known/atproto-did": (200, did),
            "https://plc.directory/\(did)": (200, didDocument(did, aliases: ["at://alice.example.com"])),
        ])
        let identity = try await ATProtoIdentityResolver(dns: dns, fetch: web.fetch).resolve("alice.example.com")
        XCTAssertEqual(identity.did.rawValue, did)
    }

    func testUnresolvableHandleFails() async {
        let web = FakeWeb(documents: ["https://alice.example.com/.well-known/atproto-did": (404, "")])
        await assertNotVerified(ATProtoIdentityResolver(dns: FakeDNS(), fetch: web.fetch), "alice.example.com")
    }

    // MARK: Bidirectional verification

    func testHandleMustBeClaimedByTheDIDDocument() async {
        let dns = FakeDNS(answers: ["_atproto.alice.example.com": .success(["did=\(did)"])])
        let web = FakeWeb(documents: [
            "https://plc.directory/\(did)": (200, didDocument(did, aliases: ["at://mallory.example.com"])),
        ])
        await assertNotVerified(ATProtoIdentityResolver(dns: dns, fetch: web.fetch), "alice.example.com")
    }

    func testDIDDocumentWithoutAliasesDoesNotVerifyAHandle() async {
        let dns = FakeDNS(answers: ["_atproto.alice.example.com": .success(["did=\(did)"])])
        let web = FakeWeb(documents: ["https://plc.directory/\(did)": (200, didDocument(did, aliases: []))])
        await assertNotVerified(ATProtoIdentityResolver(dns: dns, fetch: web.fetch), "alice.example.com")
    }

    func testClaimedHandleComparesCaseInsensitively() async throws {
        let dns = FakeDNS(answers: ["_atproto.alice.example.com": .success(["did=\(did)"])])
        let web = FakeWeb(documents: [
            "https://plc.directory/\(did)": (200, didDocument(did, aliases: ["at://Alice.Example.COM"])),
        ])
        let identity = try await ATProtoIdentityResolver(dns: dns, fetch: web.fetch).resolve("alice.example.com")
        XCTAssertEqual(identity.handle, "alice.example.com")
    }

    func testDIDInputNeedsNoHandle() async throws {
        let web = FakeWeb(documents: ["https://plc.directory/\(did)": (200, didDocument(did, aliases: []))])
        let identity = try await ATProtoIdentityResolver(dns: FakeDNS(), fetch: web.fetch).resolve(did)
        XCTAssertNil(identity.handle)
    }

    private func assertNotVerified(_ resolver: ATProtoIdentityResolver, _ identifier: String,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await resolver.resolve(identifier)
            XCTFail("\(identifier) resolved", file: file, line: line)
        } catch OAuthError.handleNotVerified {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
