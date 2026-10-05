#if canImport(BackendGTK4)
import XCTest
import CGTK
import CGTKBridge
import SwiftOpenUI
@_spi(SwiftOpenUIBackend) import BackendGTK4
@testable import HummingbirdKit

final class PlayerControlsInteractionTests: XCTestCase {
    @MainActor
    func testPointerMotionPreservesButtonsAndPauseAction() async throws {
        if gtk_is_initialized() == 0 { _ = gtk_init_check() }
        guard gtk_is_initialized() != 0 else { throw XCTSkip("no GTK display") }
        let backend = ControlsBackend()
        let model = PlayerModel(backend: backend)
        model.togglePlayback()
        let root = widgetFromOpaque(gtkRenderView(PlayerControls(model: model, isFullscreen: false)))
        let window = gtk_window_new()!
        gtk_window_set_default_size(windowPointer(window), 800, 450)
        gtk_window_set_child(windowPointer(window), root)
        gtk_widget_set_visible(window, 1)
        defer { model.teardown(); gtk_window_destroy(windowPointer(window)) }
        pump()

        let originalButtons = buttons(in: root)
        XCTAssertGreaterThanOrEqual(originalButtons.count, 3)
        let pause = try XCTUnwrap(originalButtons.dropFirst().first)
        // Hold the original so an allocator cannot reuse its address after a rebuild.
        g_object_ref(gpointer(pause))
        defer { g_object_unref(gpointer(pause)) }
        for index in 0..<20 {
            let controller = try XCTUnwrap(hoverController(in: root))
            gtk_swift_emit_motion(controller, Double(30 + index), 30)
            pump()
            XCTAssertEqual(buttons(in: root).dropFirst().first, pause,
                           "pointer motion must not replace a button before release")
        }
        XCTAssertNotEqual(gtk_widget_activate(pause), 0)
        for _ in 0..<40 {
            pump()
            if !model.isPlaying { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isPlaying, "the preserved Pause button must still invoke its action")
        XCTAssertEqual(backend.pauseCount, 1)
    }

    private func pump() {
        for _ in 0..<100 where g_main_context_pending(nil) != 0 {
            _ = g_main_context_iteration(nil, 0)
        }
    }

    private func buttons(in widget: UnsafeMutablePointer<GtkWidget>) -> [UnsafeMutablePointer<GtkWidget>] {
        if String(cString: g_type_name(gtk_swift_get_widget_type(widget))) == "GtkButton" { return [widget] }
        var result: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            result += buttons(in: current)
            child = gtk_widget_get_next_sibling(current)
        }
        return result
    }

    private func hoverController(in widget: UnsafeMutablePointer<GtkWidget>) -> OpaquePointer? {
        let object = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self)
        if let pointer = g_object_get_data(object, "gtk-swift-continuous-hover-controller") {
            return OpaquePointer(pointer)
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let controller = hoverController(in: current) { return controller }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
}

@MainActor
private final class ControlsBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying = false
    var pauseCount = 0
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false; pauseCount += 1 }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}
#endif
