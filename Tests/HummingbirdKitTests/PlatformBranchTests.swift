import Foundation
import XCTest

/// HummingbirdKit states one behaviour for every platform. Where operating
/// systems or UI backends differ, SwiftOpenUI provides one API and each
/// backend implements it (adaptive controls, `browserWindowChrome`,
/// `videoFullscreenPresentation`, PlatformSupport, CredentialStorage's
/// `optInFallback`, …). So HummingbirdKit sources may not branch on the
/// operating system or UI backend: no `#if os(…)`, `canImport(UIKit)`,
/// `canImport(AppKit)` or `BACKEND_GTK` conditions, except the debt listed in
/// `allowed`, which may only shrink.
final class PlatformBranchTests: XCTestCase {
    /// Files that may still branch, with the most branches each may have and
    /// why. Lower a maximum (or delete the entry) as the debt is paid; never
    /// raise one, and never add an entry for new code: add the SwiftOpenUI API.
    private static let allowed: [String: (maximum: Int, reason: String)] = [
        // Embedded web pages. Apple builds use SwiftOpenUI.WebPage over
        // WKWebView, GTK builds with WebKitGTK use the WebKit module's
        // WebPage, and tvOS and GTK builds without WebKitGTK have none. The
        // fix is one WebPage/WebView API exported by the SwiftOpenUI facade
        // on every backend, with `isSupported` for the ones without pages.
        "UI/Views/WebAuthView.swift": (1, "embedded web page (browser login); needs SwiftOpenUI's portable WebPage"),
        "UI/Views/ManualAuthView.swift": (1, "the pairing login used where there is no embedded web page"),
        "UI/Views/OAuthAuthorizationView.swift": (4, "embedded web page (OAuth tab); needs SwiftOpenUI's portable WebPage"),
        "UI/OAuthTabPresenter.swift": (1, "whether this build can show web pages in a tab"),
        "UI/AppModel.swift": (1, "releases the OAuth tab's web page"),
        "Core/Plugin/PluginBrowserPackage.swift": (
            2, "Grayjay's Browser package is a hidden WKWebView; needs a SwiftOpenUI headless-page API that WebKitGTK also implements"
        ),
        // Playback backends: owned by the playback work, moving separately.
        "UI/Playback/AVMediaBackend.swift": (15, "AVFoundation playback backend (UIKit/AppKit player views); moving to SwiftOpenUI"),
        "UI/Playback/GTKMediaBackend.swift": (1, "GStreamer playback backend; moving to SwiftOpenUI with AVMediaBackend"),
    ]

    func testHummingbirdKitHasNoPlatformBranchesBeyondTheAllowedDebt() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HummingbirdKit")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var counts: [String: [Int]] = [:]
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let relative = String(file.standardizedFileURL.path.dropFirst(sources.standardizedFileURL.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() where Self.isPlatformBranch(line) {
                counts[relative, default: []].append(index + 1)
            }
        }
        XCTAssertGreaterThan(scanned, 50, "found no HummingbirdKit sources under \(sources.path)")

        var offenders: [String] = []
        for (file, lines) in counts.sorted(by: { $0.key < $1.key }) {
            let maximum = Self.allowed[file]?.maximum ?? 0
            if lines.count > maximum {
                offenders.append("\(file): \(lines.count) platform branches (allowed \(maximum)) at lines \(lines)")
            }
        }
        XCTAssertEqual(offenders, [], """
            HummingbirdKit must not branch on the platform or UI backend. Put the difference in \
            SwiftOpenUI behind one API that every backend implements, and call that here.
            """)
    }

    func testTheCheckRecognisesPlatformBranches() {
        XCTAssertTrue(Self.isPlatformBranch("#if os(tvOS)"))
        XCTAssertTrue(Self.isPlatformBranch("    #elseif canImport(UIKit)"))
        XCTAssertTrue(Self.isPlatformBranch("#if canImport(AppKit) && DEBUG"))
        XCTAssertTrue(Self.isPlatformBranch("        #if !BACKEND_GTK"))
        XCTAssertTrue(Self.isPlatformBranch("#if (os(iOS) || os(macOS)) && !BACKEND_GTK"))
        XCTAssertFalse(Self.isPlatformBranch("#if DEBUG"))
        XCTAssertFalse(Self.isPlatformBranch("#if canImport(FoundationNetworking)"))
        XCTAssertFalse(Self.isPlatformBranch("// #if os(iOS) in a comment"))
        XCTAssertFalse(Self.isPlatformBranch("let ios = os(\"x\")"))
    }

    private static func isPlatformBranch(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#if(") || trimmed.hasPrefix("#elseif ") else {
            return false
        }
        return ["os(", "canImport(UIKit)", "canImport(AppKit)", "BACKEND_GTK"].contains { trimmed.contains($0) }
    }
}
