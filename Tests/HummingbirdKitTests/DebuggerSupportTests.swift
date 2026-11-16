import Foundation
import XCTest
@testable import HummingbirdKit

/// What `po`, `print` and `dump` show for app types, and the state the lldb
/// `hb` commands read. Secrets must never appear.
final class DebuggerSupportTests: XCTestCase {
    private let cookieValue = "SAPISID-secret-cookie-value"
    private let headerValue = "Bearer secret-header-value"

    private func everything(_ value: Any) -> String {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped].joined(separator: "\n")
    }

    func testSourceAuthShowsNamesNeverValues() {
        let auth = SourceAuth(
            cookieMap: [".youtube.com": ["SAPISID": cookieValue]],
            headers: ["www.youtube.com": ["authorization": headerValue]],
            userAgent: "Agent/1"
        )
        let shown = everything(auth)
        XCTAssertFalse(shown.contains(cookieValue))
        XCTAssertFalse(shown.contains(headerValue))
        XCTAssertTrue(shown.contains("SAPISID"))
        XCTAssertTrue(shown.contains("authorization"))
        XCTAssertTrue(String(reflecting: auth).contains("1 cookies, 1 headers"))
    }

    func testInstalledPluginHidesSettingValuesAndScript() throws {
        let config = try JSONDecoder().decode(
            PluginConfig.self, from: Data(#"{"name":"Example","id":"example","version":3}"#.utf8)
        )
        let plugin = InstalledPlugin(config: config, script: "source.secretFunction = 1", settings: ["apiKey": "\"key-value\""])
        let shown = everything(plugin)
        XCTAssertFalse(shown.contains("key-value"))
        XCTAssertFalse(shown.contains("secretFunction"))
        XCTAssertTrue(shown.contains("apiKey"))
        XCTAssertTrue(String(reflecting: plugin).contains("example \"Example\" v3"))
    }

    func testCredentialPairingRequestHidesItsSecret() throws {
        let secret = Data("pairing-secret-bytes".utf8)
        let request = CredentialPairingRequest(
            endpoint: try XCTUnwrap(URL(string: "http://192.0.2.1:9000/pair")), secret: secret,
            pluginID: "example", pluginSourceURL: try XCTUnwrap(URL(string: "https://example.com/config.json"))
        )
        let shown = everything(request)
        XCTAssertFalse(shown.contains("pairing-secret-bytes"))
        XCTAssertFalse(shown.contains(secret.base64EncodedString()))
        XCTAssertTrue(shown.contains("\(secret.count) bytes"))
    }

    @MainActor
    func testDebuggerStateDescribesTheNewestWindow() {
        let model = makeTestAppModel()
        let state = HummingbirdDebug.state()
        XCTAssertTrue(state.contains("AppModel(tabs: \(model.contentTabs.count)"), state)
        XCTAssertTrue(state.contains("no player in the active tab"), state)
        XCTAssertTrue(HummingbirdDebug.model === model)
        XCTAssertEqual(HummingbirdDebug.plugins(), "no plugins installed")
        let player = model.player(forTab: model.activeTabID)
        XCTAssertTrue(HummingbirdDebug.state().contains("PlayerModel(paused, 0.0/0.0s)"), HummingbirdDebug.state())
        withExtendedLifetime(player) {}
    }
}
