import XCTest
@testable import HummingbirdKit

final class PlayerLayoutTests: XCTestCase {
    func testPlayerUsesWidthUntilNinetyPercentViewportCap() {
        XCTAssertEqual(PlayerLayout.height(width: 800, viewportHeight: 900), 450)
        XCTAssertEqual(PlayerLayout.height(width: 1600, viewportHeight: 600), 540)
        XCTAssertEqual(PlayerLayout.height(width: 1600, viewportHeight: 400), 360)
    }

    func testSmallPlayerReservesBothControlBarsAndTheirPadding() {
        XCTAssertEqual(PlayerLayout.height(width: 200, viewportHeight: 600), 326)
        XCTAssertEqual(PlayerLayout.height(width: 320, viewportHeight: 600), 276)
        XCTAssertEqual(PlayerLayout.height(width: 390, viewportHeight: 600), 276)
        XCTAssertEqual(PlayerLayout.height(width: 1600, viewportHeight: 100), PlayerLayout.minimumHeight)
    }
}

#if canImport(BackendGTK4)
import CGTK
import CGTKBridge
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4

extension PlayerLayoutTests {
    @MainActor
    func testPlayerAllocationAndControlsStayAboveMetadata() async throws {
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
        for (width, viewportHeight) in [(800, 800), (1100, 400), (800, 150), (320, 600), (390, 600), (200, 600)] {
            let model = PlayerModel(backend: LayoutBackend())
            let source = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"url":"https://example.com/test.mp4"}"#.utf8))
            await model.select(PlaybackOption(id: "layout", label: "Video", kind: .progressive,
                                              video: source, audio: nil, height: 1080))
            let expectedHeight = PlayerLayout.height(width: CGFloat(width), viewportHeight: CGFloat(viewportHeight))
            let content = GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        PlayerSection(model: model, width: geometry.size.width, height: PlayerLayout.height(
                            width: geometry.size.width, viewportHeight: geometry.size.height))
                        Text("Metadata below player")
                    }
                }
            }
            let root = widgetFromOpaque(gtkRenderView(content))
            let window = gtk_window_new()!
            gtk_window_set_decorated(windowPointer(window), 0)
            gtk_window_set_default_size(windowPointer(window), gint(width), gint(viewportHeight))
            gtk_window_set_child(windowPointer(window), root)
            gtk_widget_set_visible(window, 1)
            defer { model.teardown(); gtk_window_destroy(windowPointer(window)) }
            for _ in 0..<100 {
                while g_main_context_pending(nil) != 0 { _ = g_main_context_iteration(nil, 0) }
                try await Task.sleep(nanoseconds: 10_000_000)
                if widgets(in: root).contains(where: {
                    typeName($0) == "GtkLabel" && String(cString: gtk_label_get_text(OpaquePointer($0))) == "Metadata below player"
                        && gtk_widget_get_mapped($0) != 0
                }) { break }
            }
            let descendants = widgets(in: root)
            let label = try XCTUnwrap(descendants.first {
                typeName($0) == "GtkLabel" && String(cString: gtk_label_get_text(OpaquePointer($0))) == "Metadata below player"
            })
            let metadata = origin(of: label, in: root)
            print("player layout viewport=\(gtk_widget_get_width(root))x\(gtk_widget_get_height(root)) cap=\(Double(viewportHeight) * 0.9) expectedHeight=\(expectedHeight) metadataY=\(metadata.y)")
            XCTAssertEqual(Double(metadata.y), Double(expectedHeight + 12), accuracy: 2)
            let buttons = descendants.filter { ["GtkButton", "GtkMenuButton", "GtkScale"].contains(typeName($0)) && gtk_widget_get_mapped($0) != 0 }
            XCTAssertGreaterThanOrEqual(buttons.count, 9, "exercise transport, track menus, timeline, PiP, fullscreen, and speed")
            XCTAssertEqual(gtk_widget_get_width(root), gint(width))
            for button in buttons {
                let point = origin(of: button, in: root)
                XCTAssertGreaterThanOrEqual(point.x, 0)
                XCTAssertLessThanOrEqual(Double(point.x) + Double(gtk_widget_get_width(button)), Double(width), "controls must fit horizontally at narrow widths")
                XCTAssertGreaterThanOrEqual(point.y, 0)
                XCTAssertLessThanOrEqual(Double(point.y) + Double(gtk_widget_get_height(button)), Double(expectedHeight))
                if Double(point.y) + Double(gtk_widget_get_height(button)) < Double(viewportHeight) {
                    let picked = gtk_widget_pick(root, Double(point.x) + Double(gtk_widget_get_width(button)) / 2,
                                                 Double(point.y) + Double(gtk_widget_get_height(button)) / 2, GTK_PICK_DEFAULT)
                    XCTAssertTrue(picked == button || (picked != nil && gtk_widget_is_ancestor(picked, button) != 0),
                                  "each visible control must receive hits above the metadata")
                }
            }
        }
    }

    private func widgets(in widget: UnsafeMutablePointer<GtkWidget>) -> [UnsafeMutablePointer<GtkWidget>] {
        var result = [widget]
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            result += widgets(in: current)
            child = gtk_widget_get_next_sibling(current)
        }
        return result
    }

    private func typeName(_ widget: UnsafeMutablePointer<GtkWidget>) -> String {
        String(cString: g_type_name(gtk_swift_get_widget_type(widget)))
    }

    private func origin(of widget: UnsafeMutablePointer<GtkWidget>, in root: UnsafeMutablePointer<GtkWidget>) -> graphene_point_t {
        var zero = graphene_point_t(x: 0, y: 0)
        var result = zero
        _ = gtk_widget_compute_point(widget, root, &zero, &result)
        return result
    }
}
@MainActor
private final class LayoutBackend: MediaBackend {
    var currentTime = 7200.0
    var duration = 86400.0
    var isPlaying = false
    var pictureInPictureSupported = true
    let tracks = [
        MediaTrack(id: "video", kind: .video, language: nil, label: "Video"),
        MediaTrack(id: "audio", kind: .audio, language: "en", label: "Audio"),
        MediaTrack(id: "subtitles", kind: .subtitles, language: "en", label: "Subtitles"),
    ]
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}
#endif
