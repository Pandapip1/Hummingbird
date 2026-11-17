@testable import HummingbirdKit
import XCTest

final class AddressInputTests: XCTestCase {
    func testHostsWithoutSchemeAreHTTPSAddresses() {
        XCTAssertEqual(AddressInput.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressInput.url(from: "youtube.com/watch?v=x")?.absoluteString,
                       "https://youtube.com/watch?v=x")
        XCTAssertEqual(AddressInput.url(from: "localhost:8080")?.absoluteString, "https://localhost:8080")
        XCTAssertEqual(AddressInput.url(from: "1.2.3.4/x")?.absoluteString, "https://1.2.3.4/x")
        XCTAssertEqual(AddressInput.url(from: "[::1]:8080/path")?.absoluteString, "https://[::1]:8080/path")
        XCTAssertEqual(AddressInput.url(from: "www.example.co.uk/a#b")?.absoluteString,
                       "https://www.example.co.uk/a#b")
        XCTAssertEqual(AddressInput.url(from: "  example.com  ")?.absoluteString, "https://example.com")
    }

    func testURLsWithSchemeAreKept() {
        XCTAssertEqual(AddressInput.url(from: "https://example.com/x")?.absoluteString, "https://example.com/x")
        XCTAssertEqual(AddressInput.url(from: "http://example.com")?.absoluteString, "http://example.com")
        // Other schemes are passed on for sources to recognise.
        XCTAssertEqual(AddressInput.url(from: "grayjay://plugin/x")?.absoluteString, "grayjay://plugin/x")
    }

    func testSearchesStaySearches() {
        for text in ["foo bar", "what is a.b", "foo", "3.14", "v1.2", "e.g.", "a.b",
                     "me@example.com", "", "   ", "https://", "-bad-.com", "http://no host"] {
            XCTAssertNil(AddressInput.url(from: text), "\"\(text)\" should be a search")
        }
    }
}
